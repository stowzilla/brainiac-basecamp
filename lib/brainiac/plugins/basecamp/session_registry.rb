# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Brainiac
  module Plugins
    module Basecamp
      # First-class agent session liveness tracking.
      #
      # Tracks active agent sessions by task_id (e.g., "gate-glados-1234",
      # "final-decision-1234", "epic-review-45920028") with PID, dispatch
      # timestamp, and agent name.
      #
      # The registry answers "is an agent actually running for this task?"
      # directly via PID liveness checks — replacing the prior pattern of
      # inferring liveness from Fizzy assignment or elapsed time.
      #
      # Persistence: Sessions are written to disk for crash recovery diagnostics,
      # but the registry is treated as VOLATILE — all sessions are cleared on
      # server restart (a restarted server cannot trust stale PIDs).
      #
      # Usage:
      #   SessionRegistry.register_session("gate-glados-1234", pid)
      #   SessionRegistry.alive?("gate-glados-1234")  # => true/false (checks PID)
      #   SessionRegistry.mark_dead("gate-glados-1234")
      #   SessionRegistry.sessions_for_epic("epic-45920028")
      #
      module SessionRegistry
        BRAINIAC_DIR = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
        SESSIONS_FILE = File.join(BRAINIAC_DIR, "basecamp_sessions.json")
        IMPLEMENTATION_SESSION_PREFIX = "implementation-"

        class << self
          # Register an active agent session.
          #
          # @param task_id [String] Unique key for this session (e.g. "gate-glados-1234")
          # @param pid [Integer] Process ID of the agent
          # @param log_file [String, nil] Path to the agent's log file
          # @param agent_name [String, nil] Name of the agent running
          # @param epic_id [String, nil] Epic ID this session belongs to
          # @param card_number [Integer, nil] Fizzy card number
          # @return [Hash] The registered session record
          def register_session(task_id, pid, log_file: nil, agent_name: nil, epic_id: nil, card_number: nil)
            session = {
              "task_id" => task_id.to_s,
              "pid" => pid.to_i,
              "agent_name" => agent_name,
              "epic_id" => epic_id,
              "card_number" => card_number&.to_i,
              "log_file" => log_file,
              "started_at" => Time.now.iso8601,
              "status" => "active"
            }

            sessions[task_id.to_s] = session
            persist!

            LOG.info "[Basecamp:SessionRegistry] Registered session: #{task_id} (pid=#{pid}, agent=#{agent_name})" if defined?(LOG)

            # Also forward to the global register_session if it exists (for waybar/UI).
            # Skip implementation-* sessions — fizzy already registers those as card-NNNN
            # and we don't want duplicate entries in the tray.
            if Object.respond_to?(:register_session, true) && !@suppress_global_forward &&
               !task_id.to_s.start_with?("implementation-")
              begin
                Object.send(:register_session, task_id, pid, log_file: log_file, agent_name: agent_name)
              rescue StandardError
                # Non-critical — waybar integration is optional
              end
            end

            session
          end

          # Check if a session is alive by verifying the PID is still running.
          #
          # @param task_id [String] Session task ID
          # @return [Boolean] true if session exists and its PID is alive
          def alive?(task_id)
            session = sessions[task_id.to_s]
            return false unless session
            return false if session["status"] == "dead"

            pid = session["pid"]
            return false unless pid&.positive?

            pid_alive?(pid)
          end

          # Mark a session as dead (without checking PID).
          # Use when you know the agent has finished or crashed.
          #
          # @param task_id [String] Session task ID
          # @return [Boolean] true if session existed and was marked dead
          def mark_dead(task_id)
            session = sessions[task_id.to_s]
            return false unless session

            session["status"] = "dead"
            session["ended_at"] = Time.now.iso8601
            persist!

            LOG.info "[Basecamp:SessionRegistry] Marked dead: #{task_id} (pid=#{session['pid']})" if defined?(LOG)
            true
          end

          # Get all sessions belonging to an epic.
          #
          # @param epic_id [String] Epic ID (e.g. "epic-45920028")
          # @return [Array<Hash>] Session records for this epic
          def sessions_for_epic(epic_id)
            sessions.values.select { |s| s["epic_id"] == epic_id.to_s }
          end

          # Get all active (alive) sessions for an epic.
          #
          # @param epic_id [String] Epic ID
          # @return [Array<Hash>] Active session records
          def active_sessions_for_epic(epic_id)
            sessions_for_epic(epic_id).select { |s| s["status"] == "active" && pid_alive?(s["pid"]) }
          end

          # Get session for a specific task.
          #
          # @param task_id [String] Task ID
          # @return [Hash, nil] Session record or nil
          def find_session(task_id)
            sessions[task_id.to_s]
          end

          # Check if any session is alive for a given card number.
          # Searches all sessions (gates, final decision, epic review) for this card.
          #
          # @param card_number [Integer] Fizzy card number
          # @return [Boolean]
          def any_alive_for_card?(card_number)
            sessions.values.any? do |s|
              s["card_number"] == card_number.to_i &&
                s["status"] == "active" &&
                pid_alive?(s["pid"])
            end
          end

          # Stable task ID for the implementation agent assigned to a Fizzy card.
          # Keep this distinct from gate and final-decision IDs so a live reviewer
          # cannot prevent implementation work from being re-dispatched.
          def implementation_session_id(card_number)
            "#{IMPLEMENTATION_SESSION_PREFIX}#{card_number.to_i}"
          end

          def implementation_alive?(card_number)
            alive?(implementation_session_id(card_number))
          end

          # Mirror Fizzy's real implementation-agent spawn into this registry.
          # Fizzy invokes the global register_session("card-<number>", pid) immediately
          # after run_agent returns; Basecamp installs a small observer around that
          # method so it can attach epic metadata without duplicating Fizzy dispatch.
          def track_global_implementation_session(card_key, pid, log_file: nil, agent_name: nil)
            match = /\Acard-(\d+)\z/.match(card_key.to_s)
            return unless match

            card_number = match[1].to_i
            epic = Orchestrator.find_epic_for_card(card_number)
            return unless epic

            register_session(
              implementation_session_id(card_number), pid,
              log_file: log_file,
              agent_name: agent_name,
              epic_id: epic["id"],
              card_number: card_number
            )
          end

          # Installs the observer once the core session helper is available. Keeping
          # the wrapper here means Basecamp remains compatible with the normal Fizzy
          # assignment flow, while liveness remains owned by SessionRegistry.
          def install_global_registration_hook!
            return if @global_registration_hook_installed
            return unless Object.private_method_defined?(:register_session)

            observer = Module.new do
              def register_session(card_key, pid, **kwargs)
                result = super
                Brainiac::Plugins::Basecamp::SessionRegistry.track_global_implementation_session(
                  card_key,
                  pid,
                  log_file: kwargs[:log_file],
                  agent_name: kwargs[:agent_name]
                )
                result
              end
            end

            Object.prepend(observer)
            @global_registration_hook_installed = true
          end

          # Get all active sessions for a card number.
          #
          # @param card_number [Integer] Fizzy card number
          # @return [Array<Hash>]
          def active_sessions_for_card(card_number)
            sessions.values.select do |s|
              s["card_number"] == card_number.to_i &&
                s["status"] == "active" &&
                pid_alive?(s["pid"])
            end
          end

          # Clear all sessions. Called on server restart.
          # Marks all sessions as dead since we can't trust PIDs after restart.
          #
          # @return [Integer] Number of sessions cleared
          def clear_all!
            count = sessions.size
            sessions.each_value do |s|
              s["status"] = "dead"
              s["ended_at"] = Time.now.iso8601
            end
            persist!

            LOG.info "[Basecamp:SessionRegistry] Cleared #{count} session(s) on startup" if defined?(LOG) && count.positive?
            count
          end

          # Sweep dead sessions from memory (cleanup stale entries older than threshold).
          # Keeps dead sessions on disk for diagnostics but removes from active tracking.
          #
          # @param max_age [Integer] Maximum age in seconds for dead sessions (default: 1 hour)
          # @return [Integer] Number of sessions swept
          def sweep!(max_age: 3600)
            now = Time.now
            swept = 0

            sessions.delete_if do |_task_id, session|
              next false unless session["status"] == "dead"

              ended_at = session["ended_at"]
              # Orphaned entries (dead with no ended_at) are corrupt/abnormal — remove immediately
              if ended_at.nil?
                swept += 1
                next true
              end

              age = now - Time.parse(ended_at)
              if age > max_age
                swept += 1
                true
              else
                false
              end
            end

            persist! if swept.positive?
            swept
          end

          # Reap sessions whose PIDs are no longer alive.
          # Call this periodically to detect agents that crashed without notification.
          #
          # @return [Array<String>] Task IDs that were reaped
          def reap_dead!
            reaped = []

            sessions.each do |task_id, session|
              next unless session["status"] == "active"

              pid = session["pid"]
              next unless pid&.positive?
              next if pid_alive?(pid)

              session["status"] = "dead"
              session["ended_at"] = Time.now.iso8601
              session["death_reason"] = "pid_exited"
              reaped << task_id
              LOG.info "[Basecamp:SessionRegistry] Reaped dead session: #{task_id} (pid=#{pid} no longer running)" if defined?(LOG)
            end

            persist! if reaped.any?
            reaped
          end

          # Summary of current session state (for API/diagnostics).
          #
          # @return [Hash]
          def status
            active_count = sessions.values.count { |s| s["status"] == "active" && pid_alive?(s["pid"]) }
            dead_count = sessions.values.count { |s| s["status"] == "dead" || (s["status"] == "active" && !pid_alive?(s["pid"])) }

            {
              "total" => sessions.size,
              "active" => active_count,
              "dead" => dead_count,
              "sessions" => sessions.values.map do |s|
                {
                  "task_id" => s["task_id"],
                  "pid" => s["pid"],
                  "agent_name" => s["agent_name"],
                  "epic_id" => s["epic_id"],
                  "card_number" => s["card_number"],
                  "status" => s["status"] == "active" && pid_alive?(s["pid"]) ? "active" : "dead",
                  "started_at" => s["started_at"]
                }
              end
            }
          end

          # Suppress forwarding to global register_session (for testing).
          # @api private
          attr_writer :suppress_global_forward

          # Reset internal state (for testing).
          # @api private
          def reset!
            @sessions = {}
            @suppress_global_forward = false
          end

          private

          # In-memory session store.
          def sessions
            @sessions ||= {}
          end

          # Check if a PID is alive.
          #
          # @param pid [Integer] Process ID
          # @return [Boolean]
          def pid_alive?(pid)
            return false unless pid&.positive?

            Process.kill(0, pid)
            true
          rescue Errno::ESRCH
            # No such process
            false
          rescue Errno::EPERM
            # Process exists but we don't have permission to signal it —
            # it's still alive
            true
          end

          # Persist current sessions to disk for diagnostics.
          def persist!
            data = {
              "sessions" => sessions,
              "updated_at" => Time.now.iso8601
            }

            FileUtils.mkdir_p(File.dirname(SESSIONS_FILE))
            File.write(SESSIONS_FILE, JSON.pretty_generate(data))
          rescue StandardError => e
            LOG.warn "[Basecamp:SessionRegistry] Failed to persist sessions: #{e.message}" if defined?(LOG)
          end
        end
      end
    end
  end
end
