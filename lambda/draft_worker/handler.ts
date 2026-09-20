import type { Handler, ScheduledEvent } from "aws-lambda";
import { maintainDraftCheckpoints } from "./maintenance.js";
import { reconstructDraft } from "./reconstruct.js";
import { DsqlDraftCheckpointRepository } from "./repository.js";

export const handler: Handler<
  ScheduledEvent | { operation: "publication"; article_id: string }
> = async (event) => {
  if ("operation" in event && event.operation === "publication") {
    const host = process.env.DSQL_HOST;
    if (!host) throw new Error("Draft worker environment is incomplete");
    const job = await DsqlDraftCheckpointRepository.forEnvironment(
      host,
      process.env.AWS_REGION,
    ).loadJob(event.article_id);
    const result = reconstructDraft(job);
    return {
      article_id: event.article_id,
      protocol: result.protocol,
      generation: result.generation,
      through: result.through,
      markdown: result.markdown,
      markdownDigest: result.markdownDigest,
    };
  }
  if (
    !("source" in event) ||
    event.source !== "aws.events" ||
    event["detail-type"] !== "Scheduled Event"
  )
    throw new Error("Unsupported draft maintenance event");
  const host = process.env.DSQL_HOST;
  if (!host) throw new Error("Draft worker environment is incomplete");
  const repository = DsqlDraftCheckpointRepository.forEnvironment(
    host,
    process.env.AWS_REGION,
  );
  if (process.env.DRAFT_CUTOVER_ENABLED !== "true")
    throw new Error("Draft maintenance is not activated");
  return repository.withCutoverMaintenance(() =>
    maintainDraftCheckpoints(repository),
  );
};
