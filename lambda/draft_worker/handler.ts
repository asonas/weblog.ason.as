import type { Handler, ScheduledEvent } from "aws-lambda";
import { maintainDraftCheckpoints } from "./maintenance.js";
import { migrateArticle } from "./migrateArticle.js";
import { measureOperation } from "./operationMetrics.js";
import { reconstructDraft, seedPiece } from "./reconstruct.js";
import { DsqlDraftCheckpointRepository } from "./repository.js";

type DraftWorkerEvent =
  | ScheduledEvent
  | { operation: "publication"; article_id: string }
  | { operation: "publication_batch"; article_ids: string[] }
  | { operation: "seed_piece"; piece_id: string; body: string }
  | { operation: "migration"; article_id: string; diary: boolean };

export const handler: Handler<DraftWorkerEvent> = async (event, context) => {
  const operation = "operation" in event ? event.operation : "maintenance";
  const workload = [
    "publication",
    "publication_batch",
    "seed_piece",
    "migration",
    "maintenance",
  ].includes(operation)
    ? `draft_${operation}`
    : "draft_unknown";
  return measureOperation(workload, context.awsRequestId, () =>
    dispatch(event),
  );
};

async function dispatch(event: DraftWorkerEvent) {
  if ("operation" in event && event.operation === "seed_piece")
    return seedPiece(event.piece_id, event.body);
  if (
    ("operation" in event &&
      (event.operation === "publication" ||
        event.operation === "publication_batch")) ||
    ("operation" in event && event.operation === "migration")
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
        format: result.format,
        structure: result.structure,
        pieces: result.pieces,
        tags: result.tags,
      };
    };
    if (event.operation === "migration") {
      const result = reconstructDraft(
        await repository.loadJob(event.article_id),
      );
      if (result.format !== "legacy")
        throw new Error("Article is already migrated");
      return migrateArticle(result.data, result.through, event.diary);
    }
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
}
