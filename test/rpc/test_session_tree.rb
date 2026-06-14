require_relative "../test_helper"
require_relative "../../lib/kward/rpc/session_tree"

class TestRPCSessionTree < KwardTestCase
  FakeStore = Struct.new(:entries) do
    def session_entries(_path)
      entries
    end
  end
  FakeSession = Struct.new(:path)
  FakeRpcSession = Struct.new(:store, :session)

  def test_resolves_legacy_message_index_entry_id
    entries = [{ "id" => "a" }, { "id" => "b" }]
    tree = tree_for(entries)

    assert_equal "b", tree.resolve_entry_id("message:1")
  end

  def test_active_path_ids_walks_parent_chain
    entries = [
      { "id" => "root" },
      { "id" => "child", "parentId" => "root" }
    ]
    tree = tree_for(entries)

    assert_equal ["child", "root"], tree.active_path_ids(entries, "child")
  end

  def test_entry_predicates
    tree = tree_for([])

    assert tree.user_entry?({ "type" => "message", "id" => "1", "message" => { "role" => "user" } })
    assert tree.selectable_entry?({ "type" => "branch_summary", "id" => "1" })
    refute tree.selectable_entry?({ "type" => "message", "id" => "" })
  end

  private

  def tree_for(entries)
    Kward::RPC::SessionTree.new(FakeRpcSession.new(FakeStore.new(entries), FakeSession.new("session.jsonl")))
  end
end
