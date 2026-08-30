import {
  GetSecretValueCommand,
  SecretsManagerClient,
} from "@aws-sdk/client-secrets-manager";

export type BlueskySecret = {
  allowed_did: string;
  client_private_jwk: Record<string, unknown>;
  session_encryption_key: string;
};

export async function loadSecret(secretId: string): Promise<BlueskySecret> {
  const response = await new SecretsManagerClient({}).send(
    new GetSecretValueCommand({ SecretId: secretId }),
  );
  if (!response.SecretString)
    throw new Error("Bluesky OAuth secret has no SecretString");
  const secret = JSON.parse(response.SecretString) as Partial<BlueskySecret>;
  if (
    !secret.allowed_did ||
    !secret.client_private_jwk ||
    !secret.session_encryption_key
  ) {
    throw new Error("Bluesky OAuth secret is incomplete");
  }
  return secret as BlueskySecret;
}
