require_relative "../test_helper"
require_relative "../../lib/kward/rpc/attachment_normalizer"

class TestRPCAttachmentNormalizer < KwardTestCase
  def test_normalizes_image_attachment
    data = Base64.strict_encode64("image")
    attachments = Kward::RPC::AttachmentNormalizer.new.normalize([
      { "type" => "image", "data" => data, "mimeType" => "IMAGE/PNG", "name" => "pixel.png" }
    ])

    assert_equal [{ type: "image", data: data, mimeType: "image/png", alt: "pixel.png" }], attachments
  end

  def test_rejects_invalid_attachment_data
    error = assert_raises(ArgumentError) do
      Kward::RPC::AttachmentNormalizer.new.normalize([{ type: "image", data: "not base64", mimeType: "image/png" }])
    end

    assert_equal "Image attachment data must be valid base64", error.message
  end
end
