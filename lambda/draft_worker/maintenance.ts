import { reconstructDraft } from "./reconstruct.js";
import type { DraftCheckpointRepository } from "./repository.js";

export async function maintainDraftCheckpoints(
  repository: DraftCheckpointRepository,
  now = new Date(),
) {
  const result = {
    checked: 0,
    activated: 0,
    unchanged: 0,
    stale: 0,
    cleaned: 0,
  };
  const failures: { articleId: string; message: string }[] = [];
  for (const articleId of await repository.listArticleIds()) {
    result.checked++;
    try {
      const job = await repository.loadJob(articleId);
      if (job.updates.length >= 1_000 || job.decodedBytes >= 1024 * 1024) {
        const checkpoint = reconstructDraft(job);
        const status = await repository.activate(
          articleId,
          checkpoint,
          job.expectedCheckpoint,
        );
        result[status]++;
      }
      result.cleaned += await repository.cleanup(articleId, now);
    } catch (error) {
      failures.push({
        articleId,
        message:
          error instanceof Error ? error.message : "Unknown worker failure",
      });
    }
  }
  if (failures.length) throw new DraftMaintenanceError(result, failures);
  return result;
}

export class DraftMaintenanceError extends Error {
  constructor(
    readonly result: {
      checked: number;
      activated: number;
      unchanged: number;
      stale: number;
      cleaned: number;
    },
    readonly failures: { articleId: string; message: string }[],
  ) {
    super(
      `Draft checkpoint maintenance failed for ${failures.length} article(s)`,
    );
  }
}
