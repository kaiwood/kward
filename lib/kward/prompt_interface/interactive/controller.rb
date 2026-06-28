# Namespace for the Kward CLI agent runtime.
module Kward
  # Interactive terminal UI used by the CLI frontend.
  class PromptInterface
    # Controller object passed to interactive plugin commands. Owns the canvas
    # buffer and exposes the plugin-facing API for drawing colored cells,
    # reading keys, and controlling the loop lifecycle.
    #
    # Kward manages the actual terminal rendering: the plugin fills the canvas
    # via {#put} and {#clear_frame}, then calls {#render} to mark it dirty.
    # Kward flushes the canvas to the composer region on the next frame write.
    class InteractiveController
      # Creates a controller with the given canvas dimensions and frame rate.
      #
      # @param width [Integer] canvas width in terminal columns
      # @param height [Integer] canvas height in terminal rows
      # @param fps [Numeric] target frame rate for tick callbacks
      def initialize(width:, height:, fps:)
        @width = [width.to_i, 1].max
        @height = [height.to_i, 1].max
        @fps = [[fps.to_f, 1].max, 120].min
        @cells = Array.new(@height) { Array.new(@width) { blank_cell } }
        @dirty = true
        @keys = []
        @exited = false
        @on_tick = nil
      end

      # @return [Integer] canvas width in terminal columns
      attr_reader :width

      # @return [Integer] canvas height in terminal rows
      attr_reader :height

      # @return [Numeric] target frame rate
      attr_reader :fps

      # Sets the tick callback invoked by Kward on each frame. The block
      # receives this controller. Returning `:exit` or calling {#exit}
      # ends the loop.
      #
      # @yieldparam ui [InteractiveController] self
      # @return [void]
      def on_tick(&block)
        @on_tick = block
      end

      # Places a character at the given canvas position with optional color.
      #
      # @param row [Integer] zero-based row
      # @param col [Integer] zero-based column
      # @param char [String] single character to display
      # @param colors [Array<Symbol, String>] ANSI style names or raw SGR codes
      # @return [void]
      def put(row, col, char, *colors)
        row = row.to_i
        col = col.to_i
        return if row.negative? || row >= @height
        return if col.negative? || col >= @width

        @cells[row][col] = { char: char.to_s[0] || " ", colors: colors.flatten }
        @dirty = true
      end

      # Clears all canvas cells to blank.
      #
      # @return [void]
      def clear_frame
        @cells = Array.new(@height) { Array.new(@width) { blank_cell } }
        @dirty = true
      end

      # Marks the canvas as ready for Kward to render. Called after the plugin
      # has finished drawing a frame via {#put} and {#clear_frame}.
      #
      # @return [void]
      def render
        @dirty = true
      end

      # Whether the canvas has changes pending render. Kward checks this to
      # decide whether to write cells to the terminal.
      #
      # @return [Boolean]
      def dirty?
        @dirty
      end

      # Returns the canvas cells as a 2D array of `{ char:, colors: }` hashes.
      # Kward calls this to render the frame. Resets the dirty flag.
      #
      # @return [Array<Array<Hash>>]
      def cells
        @dirty = false
        @cells
      end

      # Returns the next pending key, or nil if none. Keys are routed by
      # Kward's main input loop via {#push_key}. Non-blocking.
      #
      # @return [String, Symbol, nil]
      def poll_key
        @keys.shift
      end

      # Requests that the interactive loop exit. Kward detects this and tears
      # down the canvas, restoring the prior composer state.
      #
      # @return [void]
      def exit
        @exited = true
      end

      # Whether exit has been requested by the plugin or forced by Kward.
      #
      # @return [Boolean]
      def exited?
        @exited
      end

      # Whether a tick callback has been registered.
      #
      # @return [Boolean]
      def tickable?
        !@on_tick.nil?
      end

      # Invokes the registered tick callback. Kward calls this on each frame.
      # Returns `:exit` if the callback requests exit.
      #
      # @return [Object, :exit, nil]
      def invoke_tick
        return nil unless @on_tick

        result = @on_tick.call(self)
        result == :exit ? :exit : nil
      end

      # Resizes the canvas dimensions. Called by Kward when the terminal
      # resizes during interactive mode.
      #
      # @param width [Integer] new canvas width
      # @param height [Integer] new canvas height (kept at original row count)
      # @return [void]
      def resize(width:, height: @height)
        @width = [width.to_i, 1].max
        new_height = [height.to_i, 1].max
        if new_height != @height
          @height = new_height
          clear_frame
          return
        end

        @cells.each do |row|
          if row.length < @width
            row.fill(blank_cell, row.length...@width)
          else
            row.slice!(@width..)
          end
        end
        @dirty = true
      end

      # Pushes a key into the internal queue. Called by Kward's input loop.
      #
      # @param key [String, Symbol] key to enqueue
      # @return [void]
      def push_key(key)
        @keys << key
      end

      # Marks the controller as exited. Called by Kward on forced exit.
      #
      # @return [void]
      def force_exit
        @exited = true
      end

      private

      def blank_cell
        { char: " ", colors: [] }
      end
    end
  end
end
