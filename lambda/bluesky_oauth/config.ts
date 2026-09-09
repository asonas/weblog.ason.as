import { GetParameterCommand, SSMClient } from "@aws-sdk/client-ssm";

export type BlueskySecret = {
  allowed_did: string;
  client_private_jwk: Record<string, unknown>;
  session_encryption_key: string;
};

export async function loadSecret(secretId: string): Promise<BlueskySecret> {
  const response = await new SSMClient({}).send(
    new GetParameterCommand({ Name: `/${secretId}`, WithDecryption: true }),
  );
  if (!response.Parameter?.Value)
    throw new Error("Bluesky OAuth secret has no parameter value");
  const secret = JSON.parse(
    response.Parameter?.Value,
  ) as Partial<BlueskySecret>;
  if (
    !secret.allowed_did ||
    !secret.client_private_jwk ||
    !secret.session_encryption_key
  ) {
    throw new Error("Bluesky OAuth secret is incomplete");
  }
  return secret as BlueskySecret;
}
