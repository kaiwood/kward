require "thread"
require_relative "../cancellation"

# Namespace for the Kward CLI agent runtime.
module Kward
  # Idempotent cleanup registration owned by a plugin runtime.
  class PluginDisposable
    def initialize(resource = nil, &cleanup)
      raise ArgumentError, "plugin cleanup requires a block or closeable resource" unless cleanup || resource&.respond_to?(:close)

      @resource = resource
      @cleanup = cleanup
      @mutex = Mutex.new
      @disposed = false
    end

    def disposed?
      @mutex.synchronize { @disposed }
    end

    def dispose
      cleanup = @mutex.synchronize do
        return false if @disposed

        @disposed = true
        @cleanup
      end

      if cleanup
        cleanup.arity.zero? ? cleanup.call : cleanup.call(@resource)
      else
        @resource.close
      end
      true
    end
  end

  # Cooperative background task owned by a plugin runtime.
  class PluginTask
    attr_reader :name, :cancellation

    def initialize(name:, cancellation:, &work)
      @name = name.to_s.freeze
      @cancellation = cancellation
      @work = work
      @mutex = Mutex.new
      @thread = nil
      @result = nil
      @error = nil
    end

    def start(&finished)
      @mutex.synchronize do
        raise "Plugin task #{name.inspect} has already started" if @thread

        @thread = Thread.new do
          begin
            cancellation.raise_if_cancelled!
            result = @work.arity.zero? ? @work.call : @work.call(cancellation)
            @mutex.synchronize { @result = result }
          rescue Cancellation::CancelledError
            nil
          rescue StandardError => e
            @mutex.synchronize { @error = e }
          ensure
            finished&.call(self)
          end
        end
        @thread.report_on_exception = false
      end
      self
    end

    def cancel!
      cancellation.cancel!
      self
    end

    def cancelled?
      cancellation.cancelled?
    end

    def alive?
      thread = @mutex.synchronize { @thread }
      thread&.alive? == true
    end

    def complete?
      !alive?
    end

    def join(timeout = nil)
      thread = @mutex.synchronize { @thread }
      thread&.join(timeout)
      self
    end

    def result
      join
      @mutex.synchronize { @result }
    end

    def error
      @mutex.synchronize { @error }
    end
  end

  # Owns cleanup callbacks and cooperative background tasks for a plugin or tab.
  class PluginResources
    DEFAULT_SHUTDOWN_TIMEOUT = 1.0

    def initialize(name:, warning_sink: nil)
      @name = name.to_s
      @warning_sink = warning_sink
      @mutex = Mutex.new
      @state = :initialized
      @tasks = []
      @disposables = []
      @next_task_id = 0
    end

    def activate!
      @mutex.synchronize do
        raise "#{@name} resources have already been stopped" if @state == :stopped

        @state = :active
      end
      self
    end

    def background(name: nil, cancellation: nil, &work)
      raise ArgumentError, "plugin background task requires a block" unless work

      task = @mutex.synchronize do
        raise "#{@name} background work cannot start before plugin activation" unless @state == :active

        @next_task_id += 1
        task_name = name.to_s.empty? ? "task-#{@next_task_id}" : name.to_s
        task_cancellation = Cancellation.new
        cancellation&.on_cancel { task_cancellation.cancel! }
        PluginTask.new(name: task_name, cancellation: task_cancellation, &work).tap do |created|
          @tasks << created
          created.start { |finished| finish_task(finished) }
        end
      end
      task
    end

    def on_cleanup(resource = nil, &cleanup)
      disposable = PluginDisposable.new(resource, &cleanup)
      @mutex.synchronize do
        raise "#{@name} resources have already been stopped" if @state == :stopped

        @disposables << disposable
      end
      disposable
    end

    alias manage on_cleanup

    def shutdown(timeout: DEFAULT_SHUTDOWN_TIMEOUT)
      tasks, disposables = @mutex.synchronize do
        return self if @state == :stopped

        @state = :stopped
        [@tasks.dup, @disposables.reverse]
      end

      tasks.each(&:cancel!)
      disposables.each { |disposable| dispose(disposable) }
      join_tasks(tasks, timeout)
      self
    end

    private

    def finish_task(task)
      error = task.error
      @mutex.synchronize { @tasks.delete(task) }
      warn("#{@name} background task #{task.name.inspect} failed: #{error.message}") if error
    end

    def dispose(disposable)
      disposable.dispose
    rescue StandardError => e
      warn("#{@name} cleanup failed: #{e.message}")
    end

    def join_tasks(tasks, timeout)
      deadline = monotonic_time + [timeout.to_f, 0].max
      tasks.each do |task|
        remaining = deadline - monotonic_time
        task.join(remaining) if remaining.positive?
        warn("#{@name} background task #{task.name.inspect} did not stop before shutdown") if task.alive?
      end
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def warn(message)
      @warning_sink ? @warning_sink.call("Warning: #{message}") : Kernel.warn("Warning: #{message}")
    end
  end
end
