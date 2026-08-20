# frozen_string_literal: true

require "open3"

module Brainiac
  module Plugins
    module Basecamp
      # Manages epic branches — one per repo involved in the epic.
      # Handles creation, PR auto-merge, and final PR to main.
      module EpicBranch
        BRAINIAC_DIR = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))

        class << self
          # Create epic branches for all repos involved in an epic.
          # Called when orchestration starts.
          #
          # @param epic [Hash] Epic state
          # @param project_repos [Hash<String, String>] project_key => repo_path mapping
          # @return [Hash<String, String>] project_key => epic branch name
          def create_epic_branches(epic, project_repos)
            slug = branch_slug(epic["title"])
            branches = {}

            project_repos.each do |project_key, repo_path|
              branch_name = "epic/#{slug}"
              default_branch = detect_default_branch(repo_path)

              # Fetch latest
              run_git("fetch", "origin", chdir: repo_path)

              # Check if branch already exists remotely
              remote_exists = system("git", "ls-remote", "--exit-code", "--heads", "origin", branch_name,
                                     chdir: repo_path, out: File::NULL, err: File::NULL)

              if remote_exists
                # Branch exists — make sure we have it locally
                run_git("fetch", "origin", "#{branch_name}:#{branch_name}", chdir: repo_path)
                LOG.info "[Basecamp:EpicBranch] Reusing existing epic branch '#{branch_name}' in #{project_key}" if defined?(LOG)
              else
                # Create new branch from default branch
                run_git("branch", branch_name, "origin/#{default_branch}", chdir: repo_path)
                run_git("push", "-u", "origin", branch_name, chdir: repo_path)
                LOG.info "[Basecamp:EpicBranch] Created epic branch '#{branch_name}' in #{project_key}" if defined?(LOG)
              end

              branches[project_key] = branch_name
            end

            branches
          end

          # Auto-merge a task PR into the epic branch.
          # Called after a task completes and its PR is ready.
          #
          # @param repo_path [String] Path to the repo
          # @param branch_name [String] The task's branch name
          # @param epic_branch [String] The epic branch to merge into
          # @return [Boolean] Whether the merge succeeded
          def merge_task_into_epic(repo_path:, branch_name:, epic_branch:)
            # Find the PR for this branch
            pr_number = find_pr_for_branch(repo_path: repo_path, branch: branch_name, base: epic_branch)
            unless pr_number
              LOG.warn "[Basecamp:EpicBranch] No PR found for branch '#{branch_name}' targeting '#{epic_branch}'" if defined?(LOG)
              return false
            end

            # Merge the PR
            stdout, stderr, status = Open3.capture3(
              "gh", "pr", "merge", pr_number.to_s, "--merge", "--delete-branch",
              chdir: repo_path
            )

            if status.success?
              LOG.info "[Basecamp:EpicBranch] Merged PR ##{pr_number} into '#{epic_branch}'" if defined?(LOG)
              true
            else
              LOG.error "[Basecamp:EpicBranch] Failed to merge PR ##{pr_number}: #{stderr.strip}" if defined?(LOG)
              false
            end
          rescue StandardError => e
            LOG.error "[Basecamp:EpicBranch] Merge failed: #{e.message}" if defined?(LOG)
            false
          end

          # Open final PRs from epic branches to main for each repo.
          # Called when all epic tasks are complete.
          #
          # @param epic [Hash] Epic state
          # @param project_repos [Hash<String, String>] project_key => repo_path
          # @param epic_branches [Hash<String, String>] project_key => epic branch name
          # @return [Array<Hash>] Created PR info [{project, pr_number, url}]
          def open_final_prs(epic, project_repos, epic_branches)
            prs = []

            epic_branches.each do |project_key, epic_branch|
              repo_path = project_repos[project_key]
              next unless repo_path

              default_branch = detect_default_branch(repo_path)

              # Check if epic branch has commits ahead of main
              run_git("fetch", "origin", chdir: repo_path)
              ahead = run_git("rev-list", "--count", "origin/#{default_branch}..origin/#{epic_branch}", chdir: repo_path).strip.to_i

              if ahead.zero?
                LOG.info "[Basecamp:EpicBranch] No changes in '#{epic_branch}' for #{project_key}, skipping final PR" if defined?(LOG)
                next
              end

              # Open the PR
              title = epic["title"].sub(/^Epic:\s*/i, "")
              task_count = (epic["tasks"] || []).count { |t| t.dig("project") == project_key || project_repos.size == 1 }

              pr_body = build_final_pr_body(epic, project_key)

              stdout, stderr, status = Open3.capture3(
                "gh", "pr", "create",
                "--base", default_branch,
                "--head", epic_branch,
                "--title", "[Epic] #{title}",
                "--body", pr_body,
                chdir: repo_path
              )

              if status.success?
                pr_url = stdout.strip
                pr_number = pr_url.split("/").last
                LOG.info "[Basecamp:EpicBranch] Final PR opened: #{pr_url}" if defined?(LOG)
                prs << { project: project_key, pr_number: pr_number, url: pr_url, epic_branch: epic_branch }
              else
                LOG.error "[Basecamp:EpicBranch] Failed to open final PR for #{project_key}: #{stderr.strip}" if defined?(LOG)
              end
            end

            prs
          end

          # Get the epic branch for a given card number (if it's in an active epic).
          #
          # @param card_number [Integer, String] Fizzy card number
          # @return [String, nil] Epic branch name or nil
          def epic_branch_for_card(card_number)
            epic = Orchestrator.find_epic_for_card(card_number.to_i)
            return nil unless epic
            return nil unless epic["review_gate"] == "epic_branch"

            epic_branches = epic["epic_branches"] || {}
            # Find the project for this card's task
            task = epic["tasks"]&.find { |t| t["fizzy_card"] == card_number.to_i }
            return nil unless task

            project_key = task["project"]
            epic_branches[project_key]
          end

          private

          # Generate a URL-safe slug from the epic title.
          def branch_slug(title)
            title
              .sub(/^Epic:\s*/i, "")
              .downcase
              .gsub(/[^a-z0-9\s-]/, "")
              .gsub(/\s+/, "-")
              .gsub(/-+/, "-")
              .slice(0, 50)
              .sub(/-$/, "")
          end

          # Find a PR for a given branch targeting a specific base.
          def find_pr_for_branch(repo_path:, branch:, base:)
            stdout, _stderr, status = Open3.capture3(
              "gh", "pr", "list", "--head", branch, "--base", base, "--json", "number", "--jq", ".[0].number",
              chdir: repo_path
            )
            return nil unless status.success?

            number = stdout.strip
            number.empty? ? nil : number.to_i
          end

          # Build the body for the final epic PR.
          def build_final_pr_body(epic, project_key)
            tasks = (epic["tasks"] || []).select { |t| t["project"] == project_key || true }
            lines = []
            lines << "## Epic: #{epic['title']}"
            lines << ""
            lines << "Automated epic completion — all tasks in this epic have been completed."
            lines << ""
            lines << "### Tasks"
            tasks.each do |task|
              lines << "- [x] #{task['title']} (Fizzy ##{task['fizzy_card']})"
            end
            lines << ""
            lines << "---"
            lines << "*Opened by brainiac-basecamp epic orchestrator*"
            lines.join("\n")
          end

          # Detect the default branch for a repo.
          def detect_default_branch(repo_path)
            ref = `git -C #{repo_path} symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null`.strip
            ref.empty? ? "main" : ref.sub("origin/", "")
          end

          # Run a git command, raising on failure.
          def run_git(*args, chdir:)
            stdout, stderr, status = Open3.capture3("git", *args, chdir: chdir)
            unless status.success?
              raise "git #{args.first} failed: #{stderr.strip}"
            end
            stdout
          rescue Errno::ENOENT
            raise "git not found"
          end
        end
      end
    end
  end
end
