// verify-purchase
//
// Replaces the old client-trusted `activate_subscription` RPC (see
// 006_secure_subscription_activation.sql). The Swift client
// (SupabaseSubscription.activateSubscription(signedTransaction:)) sends the
// raw StoreKit-signed JWS for a completed purchase here. This function:
//
//   1. Identifies the calling user from their Supabase session (anonymous
//      auth — see SupabaseConfig.swift), via the Authorization header.
//   2. Independently re-verifies the JWS against Apple's own root
//      certificates using Apple's official server library — StoreKit's
//      on-device VerificationResult already checked this once, but that
//      result never leaves the device, so the server has to redo it.
//   3. Confirms the transaction is for OUR product
//      (ekme.TenScrolls.plus.monthly), isn't revoked, and (for a
//      subscription) hasn't expired.
//   4. Only then calls activate_subscription_verified() — a Postgres RPC
//      reachable exclusively by service_role — to flip subscription_status.
//
// Deploy: supabase functions deploy verify-purchase
//
// Required secrets (supabase secrets set ...):
//   None beyond what Supabase injects automatically (SUPABASE_URL,
//   SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ANON_KEY) — see "Auth" section below.
//
// TODO once the app has a real App Store Connect listing:
//   Set APPLE_APP_ID (the numeric App Store Connect app ID, NOT the bundle
//   ID) via `supabase secrets set APPLE_APP_ID=123456789`. It's only used
//   for the Production verifier and is safe to leave unset for Sandbox/
//   TestFlight testing before the app has shipped.

import { createClient } from "npm:@supabase/supabase-js@2";
import {
  AppStoreServerAPIClient,
  Environment,
  SignedDataVerifier,
} from "npm:@apple/app-store-server-library@1.4.0";

const BUNDLE_ID = "ekme.TenScrolls";
const PRODUCT_ID = "ekme.TenScrolls.plus.monthly";
const APPLE_APP_ID = Deno.env.get("APPLE_APP_ID"); // may be undefined pre-launch

// Apple's publicly published root CAs, used to validate the certificate
// chain embedded in every StoreKit-signed JWS. Pinned here as base64
// constants rather than fetched at runtime — an earlier version fetched
// these from apple.com on every cold start, and a stalled fetch (no
// timeout was set) let a single invocation hang until Supabase's wall-clock
// limit killed it (~150s, WORKER_RESOURCE_LIMIT). Verification now has zero
// runtime network dependency beyond Supabase itself.
//
// Re-fetch and update these only if Apple rotates its root CAs (order of
// years, not something that happens routinely):
//   curl -sSL -o root-g3.cer https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
//   curl -sSL -o root-computer.cer https://www.apple.com/certificateauthority/AppleComputerRootCertificate.cer
//   base64 -i root-g3.cer
//   base64 -i root-computer.cer
const APPLE_ROOT_CA_G3_B64 =
  "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==";

const APPLE_COMPUTER_ROOT_B64 =
  "MIIFujCCBKKgAwIBAgIBATANBgkqhkiG9w0BAQUFADCBhjELMAkGA1UEBhMCVVMxHTAbBgNVBAoTFEFwcGxlIENvbXB1dGVyLCBJbmMuMS0wKwYDVQQLEyRBcHBsZSBDb21wdXRlciBDZXJ0aWZpY2F0ZSBBdXRob3JpdHkxKTAnBgNVBAMTIEFwcGxlIFJvb3QgQ2VydGlmaWNhdGUgQXV0aG9yaXR5MB4XDTA1MDIxMDAwMTgxNFoXDTI1MDIxMDAwMTgxNFowgYYxCzAJBgNVBAYTAlVTMR0wGwYDVQQKExRBcHBsZSBDb21wdXRlciwgSW5jLjEtMCsGA1UECxMkQXBwbGUgQ29tcHV0ZXIgQ2VydGlmaWNhdGUgQXV0aG9yaXR5MSkwJwYDVQQDEyBBcHBsZSBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAOSRqQkfkdseR1DrBe1eeYQt6zaiV0xV7IsZid75S2z1B6siMALoGD74UAnTf0GomPnRymacJGsR0KO75Bsqwx+VnnoMpEeLW9QWNzPLxA9NzhRp0ckZcvVdDtV/X5vyJQO6VY9NXQ3xZDUjFUsVWR2zlPf2nJ7PULrBWFBnjwi0IPfLrCwgb3C2PwEwjLdDzw+dPfMrSSgayP7OtbkO2V4c1ss9tTqt9A8OAJILsSEWLnTVPA3bYharo3GSR1NVwa8vQbP4++NwzeajTEV+H0xrUJZBicR0YgsQg0GHM4qBsTBY7FoEMoxos48d3mVz/2deZbxJ2HafMxRloXeUyS0CAwEAAaOCAi8wggIrMA4GA1UdDwEB/wQEAwIBBjAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBQr0GlHlHYJ/vRrjS5ApvdHTX8IXjAfBgNVHSMEGDAWgBQr0GlHlHYJ/vRrjS5ApvdHTX8IXjCCASkGA1UdIASCASAwggEcMIIBGAYJKoZIhvdjZAUBMIIBCTBBBggrBgEFBQcCARY1aHR0cHM6Ly93d3cuYXBwbGUuY29tL2NlcnRpZmljYXRlYXV0aG9yaXR5L3Rlcm1zLmh0bWwwgcMGCCsGAQUFBwICMIG2GoGzUmVsaWFuY2Ugb24gdGhpcyBjZXJ0aWZpY2F0ZSBieSBhbnkgcGFydHkgYXNzdW1lcyBhY2NlcHRhbmNlIG9mIHRoZSB0aGVuIGFwcGxpY2FibGUgc3RhbmRhcmQgdGVybXMgYW5kIGNvbmRpdGlvbnMgb2YgdXNlLCBjZXJ0aWZpY2F0ZSBwb2xpY3kgYW5kIGNlcnRpZmljYXRpb24gcHJhY3RpY2Ugc3RhdGVtZW50cy4wRAYDVR0fBD0wOzA5oDegNYYzaHR0cHM6Ly93d3cuYXBwbGUuY29tL2NlcnRpZmljYXRlYXV0aG9yaXR5L3Jvb3QuY3JsMFUGCCsGAQUFBwEBBEkwRzBFBggrBgEFBQcwAoY5aHR0cHM6Ly93d3cuYXBwbGUuY29tL2NlcnRpZmljYXRlYXV0aG9yaXR5L2Nhc2lnbmVycy5odG1sMA0GCSqGSIb3DQEBBQUAA4IBAQCd2i0oWC99dgS5BNM+zrdmY06PL9T+S61yvaM5xlJNBZhS9YlRASR5vhoy9+VEi0tEBzmC1lrKtCBe2a4VXR2MHTK/ODFiSF3H4ZCx+CRA+F9Ym1FdV53B5f88zHIhbsTp6aF31ywXJsM/65roCwO66bNKcuszCVut5mIxauivL9WvHld2j383LS4CXN1jyfJxuCZA3xWNdUQ/eb3mHZnhQyw+rW++uaT+DjUZUWOxw961kj5ReAFziqQjyqSI8R5cH0EWLX6VCqrpiUGYGxrdyyC/R14MJsVVNU3GMIuZZxTHCR+6R8faAQmHJEKVvRNgGQrv6n8Obs3BREM6StXj";

function decodeBase64Cert(b64: string): Uint8Array {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function loadRootCertificates(): Uint8Array[] {
  return [decodeBase64Cert(APPLE_ROOT_CA_G3_B64), decodeBase64Cert(APPLE_COMPUTER_ROOT_B64)];
}

/// Tries Production first, then falls back to Sandbox. There's no reliable
/// way to know in advance which environment a given JWS came from without
/// decoding it first (and decoding-before-verifying defeats the point), so
/// this mirrors Apple's own recommended pattern of attempting verification
/// against both environments for apps that support both TestFlight/sandbox
/// and live purchases from the same endpoint.
async function verifyTransaction(signedTransaction: string, rootCerts: Uint8Array[]) {
  for (const environment of [Environment.PRODUCTION, Environment.SANDBOX]) {
    try {
      const verifier = new SignedDataVerifier(
        rootCerts,
        /* enableOnlineChecks */ false,
        environment,
        BUNDLE_ID,
        APPLE_APP_ID ? Number(APPLE_APP_ID) : undefined,
      );
      const payload = await verifier.verifyAndDecodeTransaction(signedTransaction);
      return payload;
    } catch {
      continue;
    }
  }
  return null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ success: false, error: "method_not_allowed" }), { status: 405 });
  }

  let signedTransaction: string | undefined;
  try {
    const body = await req.json();
    signedTransaction = body.signedTransaction;
  } catch {
    return new Response(JSON.stringify({ success: false, error: "invalid_body" }), { status: 400 });
  }
  if (!signedTransaction) {
    return new Response(JSON.stringify({ success: false, error: "missing_signed_transaction" }), { status: 400 });
  }

  // Identify the caller from their own session JWT (anonymous auth), not a
  // client-supplied user id — never trust a user id sent in the body.
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ success: false, error: "unauthenticated" }), { status: 401 });
  }
  const userClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    return new Response(JSON.stringify({ success: false, error: "unauthenticated" }), { status: 401 });
  }
  const userId = userData.user.id;

  // Verify the JWS against Apple's certificates — the actual point of this
  // whole function.
  let payload;
  try {
    const rootCerts = await loadRootCertificates();
    payload = await verifyTransaction(signedTransaction, rootCerts);
  } catch (err) {
    console.error("verify-purchase: root cert fetch or verification error", err);
    return new Response(JSON.stringify({ success: false, error: "verification_error" }), { status: 502 });
  }

  if (!payload) {
    console.error("verify-purchase: verification_failed — JWS did not verify against Production or Sandbox Apple root certs. If this build is running with a local Configuration.storekit file attached to the Xcode scheme, this is expected: local StoreKit Testing transactions are signed by a local test cert, not Apple's real cert chain, and can never pass this check.");
    return new Response(
      JSON.stringify({ success: false, error: "verification_failed", message: "Couldn't verify this purchase with Apple." }),
      { status: 400 },
    );
  }
  if (payload.productId !== PRODUCT_ID) {
    console.error(`verify-purchase: product_mismatch — expected ${PRODUCT_ID}, got ${payload.productId}`);
    return new Response(
      JSON.stringify({ success: false, error: "product_mismatch", message: "This purchase doesn't match TenScrolls Plus." }),
      { status: 400 },
    );
  }
  if (payload.revocationDate) {
    console.error(`verify-purchase: revoked — revocationDate=${payload.revocationDate}`);
    return new Response(
      JSON.stringify({ success: false, error: "revoked", message: "This purchase was refunded or revoked." }),
      { status: 400 },
    );
  }
  if (payload.expiresDate && payload.expiresDate < Date.now()) {
    console.error(`verify-purchase: expired — expiresDate=${payload.expiresDate}, now=${Date.now()}`);
    return new Response(
      JSON.stringify({ success: false, error: "expired", message: "This subscription has already expired." }),
      { status: 400 },
    );
  }

  // Verified — now activate, via the service-role-only Postgres RPC.
  const adminClient = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const { data: rpcResult, error: rpcError } = await adminClient.rpc("activate_subscription_verified", {
    p_user_id: userId,
    p_original_transaction_id: String(payload.originalTransactionId),
    p_latest_transaction_id: String(payload.transactionId),
  });

  if (rpcError) {
    console.error("verify-purchase: activate_subscription_verified failed", rpcError);
    return new Response(JSON.stringify({ success: false, error: "activation_failed" }), { status: 500 });
  }

  return new Response(JSON.stringify(rpcResult), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
