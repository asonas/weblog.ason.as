import type { Handler, ScheduledEvent } from "aws-lambda";
import { maintainDraftCheckpoints } from "./maintenance.js";
import { reconstructDraft } from "./reconstruct.js";
import { DsqlDraftCheckpointRepository } from "./repository.js";

export const handler: Handler<
  | ScheduledEvent
  | { operation: "publication"; article_id: string }
  | { operation: "publication_batch"; article_ids: string[] }
> = async (event) => {
  if (
    "operation" in event &&
    (event.operation === "publication" ||
      event.operation === "publication_batch")
  ) {
    const host = process.env.DSQL_HOST;
    if (!host) throw new Error("Draft worker environment is incomplete");
    const repository = DsqlDraftCheckpointRepository.forEnvironment(
      host,
      process.env.AWS_REGION,
    );
    const reconstruct = async (articleId: string) => {
      const result = reconstructDraft(await repository.loadJob(articleId));
      return {
        article_id: articleId,
        protocol: result.protocol,
        generation: result.generation,
        through: result.through,
        markdown: result.markdown,
        markdownDigest: result.markdownDigest,
      };
    };
    if (event.operation === "publication_batch") {
      if (event.article_ids.length > 25)
        throw new Error("Publication batch exceeds limit");
      const results = [];
      for (const articleId of event.article_ids)
        results.push(await reconstruct(articleId));
      return results;
    }
    return reconstruct(event.article_id);
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
