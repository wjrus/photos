class QueueStatusController < ApplicationController
  owner_access_message "Only the owner can see queue status."

  before_action :require_owner!

  def show
    redirect_to repository_status_path(section: "queues")
  end

  def destroy_failures
    cleared_count = QueueStatusSnapshot.build.clear_failures

    RepositoryStatusData.invalidate(current_user.id, "queues", "health")
    redirect_to repository_status_path(section: "queues"), notice: "Cleared #{cleared_count} failed #{'job'.pluralize(cleared_count)}."
  end

  def retry_pruned_failures
    retried_count = QueueStatusSnapshot.build.retry_pruned_failures

    RepositoryStatusData.invalidate(current_user.id, "queues", "health")
    redirect_to repository_status_path(section: "queues"), notice: "Retried #{retried_count} pruned #{'job'.pluralize(retried_count)}."
  end

  def resume_pauses
    resumed_queues = QueueStatusSnapshot.build.resume_paused_queues
    message = if resumed_queues.any?
      "Resumed #{resumed_queues.to_sentence}."
    else
      "No queues were paused."
    end

    RepositoryStatusData.invalidate(current_user.id, "queues", "health")
    redirect_to repository_status_path(section: "queues"), notice: message
  end
end
