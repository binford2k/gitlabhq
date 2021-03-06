module MergeRequests
  class RefreshService < MergeRequests::BaseService
    def execute(oldrev, newrev, ref)
      return true unless Gitlab::Git.branch_ref?(ref)

      @oldrev, @newrev = oldrev, newrev
      @branch_name = Gitlab::Git.ref_name(ref)
      @fork_merge_requests = @project.fork_merge_requests.opened
      @commits = []

      # Leave a system note if a branch were deleted/added
      if Gitlab::Git.blank_ref?(oldrev) || Gitlab::Git.blank_ref?(newrev)
        comment_mr_branch_presence_changed
        comment_mr_with_commits if @commits.present?
      else
        @commits = @project.repository.commits_between(oldrev, newrev)
        comment_mr_with_commits
        close_merge_requests
      end

      reload_merge_requests
      execute_mr_web_hooks

      true
    end

    private

    # Collect open merge requests that target same branch we push into
    # and close if push to master include last commit from merge request
    # We need this to close(as merged) merge requests that were merged into
    # target branch manually
    def close_merge_requests
      commit_ids = @commits.map(&:id)
      merge_requests = @project.merge_requests.opened.where(target_branch: @branch_name).to_a
      merge_requests = merge_requests.select(&:last_commit)

      merge_requests = merge_requests.select do |merge_request|
        commit_ids.include?(merge_request.last_commit.id)
      end

      merge_requests.uniq.select(&:source_project).each do |merge_request|
        MergeRequests::PostMergeService.
          new(merge_request.target_project, @current_user).
          execute(merge_request)
      end
    end

    def force_push?
      Gitlab::ForcePushCheck.force_push?(@project, @oldrev, @newrev)
    end

    # Refresh merge request diff if we push to source or target branch of merge request
    # Note: we should update merge requests from forks too
    def reload_merge_requests
      merge_requests = @project.merge_requests.opened.by_branch(@branch_name).to_a
      merge_requests += @fork_merge_requests.by_branch(@branch_name).to_a
      merge_requests = filter_merge_requests(merge_requests)

      merge_requests.each do |merge_request|

        if merge_request.source_branch == @branch_name || force_push?
          merge_request.reload_code
          merge_request.mark_as_unchecked
        else
          mr_commit_ids = merge_request.commits.map(&:id)
          push_commit_ids = @commits.map(&:id)
          matches = mr_commit_ids & push_commit_ids

          if matches.any?
            merge_request.reload_code
            merge_request.mark_as_unchecked
          else
            merge_request.mark_as_unchecked
          end
        end
      end
    end

    # Add comment about branches being deleted or added to merge requests
    def comment_mr_branch_presence_changed
      presence = Gitlab::Git.blank_ref?(@oldrev) ? :add : :delete

      merge_requests_for_source_branch.each do |merge_request|
        last_commit = merge_request.last_commit

        # Only look at changed commits in restore branch case
        unless Gitlab::Git.blank_ref?(@newrev)
          begin
            # Since any number of commits could have been made to the restored branch,
            # find the common root to see what has been added.
            common_ref = @project.repository.merge_base(last_commit.id, @newrev)
            # If the a commit no longer exists in this repo, gitlab_git throws
            # a Rugged::OdbError. This is fixed in https://gitlab.com/gitlab-org/gitlab_git/merge_requests/52
            @commits = @project.repository.commits_between(common_ref, @newrev) if common_ref
          rescue
          end

          # Prevent system notes from seeing a blank SHA
          @oldrev = nil
        end

        SystemNoteService.change_branch_presence(
            merge_request, merge_request.project, @current_user,
            :source, @branch_name, presence)
      end
    end

    # Add comment about pushing new commits to merge requests
    def comment_mr_with_commits
      merge_requests_for_source_branch.each do |merge_request|
        mr_commit_ids = Set.new(merge_request.commits.map(&:id))

        new_commits, existing_commits = @commits.partition do |commit|
          mr_commit_ids.include?(commit.id)
        end

        SystemNoteService.add_commits(merge_request, merge_request.project,
                                      @current_user, new_commits,
                                      existing_commits, @oldrev)
      end
    end

    # Call merge request webhook with update branches
    def execute_mr_web_hooks
      merge_requests_for_source_branch.each do |merge_request|
        execute_hooks(merge_request, 'update')
      end
    end

    def filter_merge_requests(merge_requests)
      merge_requests.uniq.select(&:source_project)
    end

    def merge_requests_for_source_branch
      @source_merge_requests ||= begin
        merge_requests = @project.origin_merge_requests.opened.where(source_branch: @branch_name).to_a
        merge_requests += @fork_merge_requests.where(source_branch: @branch_name).to_a
        filter_merge_requests(merge_requests)
      end
    end
  end
end
