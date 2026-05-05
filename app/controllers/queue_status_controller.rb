class QueueStatusController < ApplicationController
  owner_access_message "Only the owner can see queue status."

  before_action :require_owner!

  def show
    @snapshot = QueueStatusSnapshot.build
    @totals = @snapshot.totals
    @queues = @snapshot.queues
    @job_classes = @snapshot.job_classes
    @recent_failures = @snapshot.recent_failures
    @processes = @snapshot.processes
    @pauses = @snapshot.pauses
    @finished_counts = @snapshot.finished_counts
  end
end
