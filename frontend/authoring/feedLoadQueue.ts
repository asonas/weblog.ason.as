export type FeedLoadRequest = {
  url: string;
  direction: "replace" | "newer" | "older";
};

export class FeedLoadQueue {
  private isRunning = false;
  private pendingReplacement: FeedLoadRequest | null = null;

  async run(request: FeedLoadRequest, load: (request: FeedLoadRequest) => Promise<void>) {
    if (this.isRunning) {
      if (request.direction === "replace") this.pendingReplacement = request;
      return;
    }

    this.isRunning = true;
    try {
      await load(request);
    } finally {
      this.isRunning = false;
      const pendingReplacement = this.pendingReplacement;
      this.pendingReplacement = null;
      if (pendingReplacement) await this.run(pendingReplacement, load);
    }
  }
}
