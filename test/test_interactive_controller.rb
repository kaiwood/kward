require_relative "test_helper"

class TestInteractiveController < KwardTestCase
  def test_put_places_character_at_position
    controller = Kward::PromptInterface::InteractiveController.new(width: 10, height: 5, fps: 30)

    controller.put(1, 2, "X", :red)

    cells = controller.cells
    assert_equal "X", cells[1][2][:char]
    assert_equal [:red], cells[1][2][:colors]
  end

  def test_put_ignores_out_of_bounds
    controller = Kward::PromptInterface::InteractiveController.new(width: 3, height: 2, fps: 30)

    controller.put(-1, 0, "X")
    controller.put(0, -1, "Y")
    controller.put(2, 0, "Z")
    controller.put(0, 3, "W")

    cells = controller.cells
    assert_equal " ", cells[0][0][:char]
    assert_equal " ", cells[0][2][:char]
  end

  def test_clear_frame_resets_all_cells
    controller = Kward::PromptInterface::InteractiveController.new(width: 4, height: 2, fps: 30)
    controller.put(0, 0, "A")
    controller.put(1, 3, "B")

    controller.clear_frame

    cells = controller.cells
    assert_equal " ", cells[0][0][:char]
    assert_equal " ", cells[1][3][:char]
  end

  def test_dirty_flag_resets_after_cells_read
    controller = Kward::PromptInterface::InteractiveController.new(width: 4, height: 2, fps: 30)

    assert controller.dirty?
    controller.cells
    refute controller.dirty?

    controller.render
    assert controller.dirty?
  end

  def test_poll_key_returns_queued_keys_in_order
    controller = Kward::PromptInterface::InteractiveController.new(width: 4, height: 2, fps: 30)

    controller.push_key(:left)
    controller.push_key(:right)

    assert_equal :left, controller.poll_key
    assert_equal :right, controller.poll_key
    assert_nil controller.poll_key
  end

  def test_exit_sets_exited_flag
    controller = Kward::PromptInterface::InteractiveController.new(width: 4, height: 2, fps: 30)

    refute controller.exited?
    controller.exit
    assert controller.exited?
  end

  def test_force_exit_sets_exited_flag
    controller = Kward::PromptInterface::InteractiveController.new(width: 4, height: 2, fps: 30)

    controller.force_exit
    assert controller.exited?
  end

  def test_on_tick_callback_is_invoked
    controller = Kward::PromptInterface::InteractiveController.new(width: 4, height: 2, fps: 30)
    tick_count = 0
    controller.on_tick { |_ui| tick_count += 1 }

    assert controller.tickable?
    controller.invoke_tick
    controller.invoke_tick

    assert_equal 2, tick_count
  end

  def test_invoke_tick_returns_exit_when_callback_returns_exit
    controller = Kward::PromptInterface::InteractiveController.new(width: 4, height: 2, fps: 30)
    controller.on_tick { :exit }

    assert_equal :exit, controller.invoke_tick
  end

  def test_resize_changes_width_preserving_content
    controller = Kward::PromptInterface::InteractiveController.new(width: 5, height: 2, fps: 30)
    controller.put(0, 0, "A")
    controller.put(0, 4, "B")

    controller.resize(width: 10)

    cells = controller.cells
    assert_equal 10, controller.width
    assert_equal "A", cells[0][0][:char]
  end

  def test_resize_shrinking_width_truncates
    controller = Kward::PromptInterface::InteractiveController.new(width: 5, height: 2, fps: 30)
    controller.put(0, 4, "B")

    controller.resize(width: 3)

    assert_equal 3, controller.width
    assert_equal 3, controller.cells[0].length
  end

  def test_fps_is_clamped
    controller = Kward::PromptInterface::InteractiveController.new(width: 4, height: 2, fps: 0.5)
    assert_equal 1.0, controller.fps

    controller2 = Kward::PromptInterface::InteractiveController.new(width: 4, height: 2, fps: 999)
    assert_equal 120, controller2.fps
  end
end
