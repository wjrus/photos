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

  def destroy_failures
    cleared_count = QueueStatusSnapshot.build.clear_failures

    redirect_to queue_status_path, notice: "Cleared #{cleared_count} failed #{'job'.pluralize(cleared_count)}."
  end
end
