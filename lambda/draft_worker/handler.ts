import type { Handler, ScheduledEvent } from "aws-lambda";
import { maintainDraftCheckpoints } from "./maintenance.js";
import { DsqlDraftCheckpointRepository } from "./repository.js";

export const handler: Handler<ScheduledEvent> = async (event) => {
  if (
    event.source !== "aws.events" ||
    event["detail-type"] !== "Scheduled Event"
  )
    throw new Error("Unsupported draft maintenance event");
  const host = process.env.DSQL_HOST;
  if (!host) throw new Error("Draft worker environment is incomplete");
  return maintainDraftCheckpoints(
    DsqlDraftCheckpointRepository.forEnvironment(host, process.env.AWS_REGION),
  );
};
