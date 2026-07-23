require_relative "test_helper"
require_relative "../lib/kward/transport"

class TestTransportStore < KwardTestCase
  def test_persists_namespaced_values_and_returns_copies
    Dir.mktmpdir do |root|
      store = Kward::Transport::Store.new("com.example.test", root: root)
      value = { "chat" => { "session" => "session-1" } }
      store.put("binding:chat", value)
      value["chat"]["session"] = "changed"

      assert_equal({ "chat" => { "session" => "session-1" } }, store.get("binding:chat"))
      assert_equal({ "chat" => { "session" => "session-1" } }, Kward::Transport::Store.new("com.example.test", root: root).get("binding:chat"))
      assert_equal 0o600, File.stat(File.join(root, "transports", "com.example.test", "state.json")).mode & 0o777
    end
  end

  def test_delete_persists_false_values
    Dir.mktmpdir do |root|
      store = Kward::Transport::Store.new("test", root: root)
      store.put("flag", false)
      assert_equal false, store.delete("flag")
      assert_nil Kward::Transport::Store.new("test", root: root).get("flag")
    end
  end

  def test_claim_is_durable_and_rejects_duplicates
    Dir.mktmpdir do |root|
      store = Kward::Transport::Store.new("test", root: root)

      assert store.claim("update:1")
      refute store.claim("update:1")
      assert Kward::Transport::Store.new("test", root: root).claim("update:2")
      refute Kward::Transport::Store.new("test", root: root).claim("update:1")
    end
  end

  def test_claim_limits_old_keys
    Dir.mktmpdir do |root|
      store = Kward::Transport::Store.new("test", root: root)

      assert store.claim("one", max_keys: 2)
      assert store.claim("two", max_keys: 2)
      assert store.claim("three", max_keys: 2)
      assert store.claim("one", max_keys: 2)
    end
  end

  def test_rejects_path_like_keys
    Dir.mktmpdir do |root|
      assert_raises(ArgumentError) { Kward::Transport::Store.new("../unsafe", root: root) }
      store = Kward::Transport::Store.new("test", root: root)
      assert_raises(ArgumentError) { store.put("../unsafe", true) }
      assert_raises(ArgumentError) { store.claim("", max_keys: 1) }
    end
  end
end
