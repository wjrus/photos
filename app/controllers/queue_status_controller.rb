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

  def resume_pauses
    resumed_queues = QueueStatusSnapshot.build.resume_paused_queues
    message = if resumed_queues.any?
      "Resumed #{resumed_queues.to_sentence}."
    else
      "No queues were paused."
    end

    redirect_to queue_status_path, notice: message
  end
end
