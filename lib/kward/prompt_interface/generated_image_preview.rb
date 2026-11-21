require_relative "../shell/kwsh"

module Kward
  class PromptInterface
    # Generated previews share the /files renderer but are not project files.
    module GeneratedImagePreview
      def offer_generated_images(offers)
        # Rendering can probe terminal capabilities, so let the input loop open it.
        @mutex.synchronize { (@generated_image_offers ||= []).concat(offers) }
      end

      # Tab switches suspend the overlay; they do not discard the image.
      def take_generated_image_offers
        @mutex.synchronize do
          offers = @generated_image_offers || []
          if (image = @image_viewer_state&.fetch(:generated, nil))
            offers.unshift(image)
            close_image_viewer
          end
          @generated_image_offers = []
          offers
        end
      end

      private

      def open_pending_generated_image_locked
        return false if @generated_image_offers.nil? || @generated_image_offers.empty?
        return false if image_viewer_active? || editor_active? || project_browser_visible? || modal_active_locked? || interactive_active_locked?

        while (offer = @generated_image_offers.shift)
          begin
            path = offer[:store].path(offer[:owner], offer[:image].id)
            @image_viewer_state = image_viewer_state_for(path, offer[:image].filename).merge(generated: offer)
            return true
          rescue GeneratedImages::Error
            next
          end
        end
        false
      end

      def handle_generated_image_key(key)
        state = @image_viewer_state
        if (picker = state[:directory_picker])
          return handle_generated_image_directory_key(key, state, picker)
        end

        case key
        when "d", "D" then save_generated_preview(:downloads)
        when "p", "P"
          clear_image_viewer_output_locked
          state.delete(:status)
          state[:directory_picker] = { text: +"", cursor: 0 }
          true
        when "\e", "q", "Q" then discard_generated_preview
        else false
        end
      end

      def handle_generated_image_directory_key(key, state, picker)
        case key
        when "\e"
          state.delete(:directory_picker)
          state.delete(:status)
        when "\r", "\n"
          save_generated_preview(:project, picker[:text].empty? ? "." : picker[:text])
        when "\t" then complete_generated_image_directory(state, picker)
        when "\x7f", "\b"
          if picker[:cursor].positive?
            picker[:cursor] -= 1
            picker[:text].slice!(picker[:cursor])
          end
          picker.delete(:cycle)
          state.delete(:status)
        else
          case key_name_for(key)
          when :left then picker[:cursor] = [picker[:cursor] - 1, 0].max
          when :right then picker[:cursor] = [picker[:cursor] + 1, picker[:text].length].min
          else
            if printable_key?(key) && picker[:text].bytesize + key.bytesize <= 4096
              picker[:text].insert(picker[:cursor], key)
              picker[:cursor] += key.length
              state.delete(:status)
            end
          end
          picker.delete(:cycle)
        end
        true
      end

      def complete_generated_image_directory(state, picker)
        if (cycle = picker[:cycle])
          cycle[:index] = (cycle[:index] + 1) % cycle[:candidates].length
          text = cycle[:candidates][cycle[:index]]
        else
          root = state[:generated][:image].root
          result = Kwsh.new(cwd: root).complete_directory(picker[:text], picker[:cursor], root: root)
          return unless result

          text = result.replacement
          picker[:cycle] = { candidates: result.candidates, index: result.candidates.index(text) || -1 } if result.candidates.size > 1
        end
        picker[:text] = text.dup
        picker[:cursor] = text.length
        state.delete(:status)
      end

      def save_generated_preview(destination, directory = nil)
        state = @image_viewer_state
        offer = state[:generated]
        store, owner, image = offer.values_at(:store, :owner, :image)
        path = if destination == :downloads
                 store.save_to_downloads(owner, image.id)
               else
                 store.save_to_project(owner, image.id, directory)
               end
        offer[:saved] = true
        state.delete(:directory_picker)
        state[:status] = "Saved to #{path.gsub(/[[:cntrl:]]/, "?")}"
        record_generated_image_status(state[:status])
        true
      rescue GeneratedImages::Error => e
        state[:status] = e.message
        true
      end

      def discard_generated_preview
        offer = @image_viewer_state[:generated]
        offer[:store].discard(offer[:owner], offer[:image].id)
        record_generated_image_status("Image discarded") unless offer[:saved]
        close_image_viewer
        open_pending_generated_image_locked
        true
      rescue GeneratedImages::Error => e
        @image_viewer_state[:status] = e.message
        true
      end

      def record_generated_image_status(text)
        append_transcript_buffer("\n#{text.gsub(/[[:cntrl:]]/, "?")}\n")
        remember_transcript_viewport_locked
        with_synchronized_output_locked { redraw_screen_locked } if @started
      end

      def generated_image_footer_rows(content_width)
        state = @image_viewer_state
        picker = state[:directory_picker]
        rows = if picker
                 text = picker[:text].dup.insert(picker[:cursor], "│")
                 [footer_row(content_width, "Project directory: #{text}"), footer_row(content_width, "Tab completes · Enter saves · Esc back")]
               else
                 actions = ["D Save to Downloads · P Save to Project…", "Esc Discard"]
                 actions = [actions.join(" · ")] if content_width >= 53
                 actions.map { |text| footer_row(content_width, text) }
               end
        rows << footer_row(content_width, state[:status]) if state[:status]
        rows
      end
    end
  end
end
