# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/weblog_authoring/image_upload"
require_relative "../../lib/weblog_authoring/image_inbox"

class ImageInboxTest < Minitest::Test
  def setup
    @s3 = Aws::S3::Client.new(region: "ap-northeast-1", stub_responses: true)
    @database = Object.new
    @inbox = WeblogAuthoring::ImageInbox.new(s3_client: @s3, bucket: "images.example", database: @database)
  end

  def test_prepares_a_pending_public_copy_without_deleting_the_inbox_image
    key = "assets/inbox/2026/08/23/11111111-2222-3333-4444-555555555555.webp"
    item = WeblogAuthoring::InboxItem.new(
      id: "item-1", source: "photo", kind: "photo", source_id: "photo-1",
      occurred_at: Time.now, ingested_at: Time.now, expires_at: Time.now + 3600,
      payload: { "inbox_key" => key, "preview_url" => "/#{key}", "captured_at_source" => "exif" },
      created_at: Time.now, updated_at: Time.now
    )
    adoption = nil
    @database.define_singleton_method(:find_inbox_item) { |_id| item }
    @database.define_singleton_method(:prepare_inbox_image_adoption) do |item_id:, inbox_key:, public_key:|
      adoption ||= WeblogAuthoring::InboxImageAdoption.new(
        item_id:, inbox_key:, public_key:, prepared_at: Time.now,
        committed_at: nil, expires_at: Time.now + 86_400
      )
    end

    result = @inbox.prepare(item_id: "item-1")

    assert_equal "/assets/uploads/2026/08/11111111-2222-3333-4444-555555555555.webp",
                 result.fetch("public_url")
    assert_equal "images.example/#{key}", @s3.api_requests[0].fetch(:params).fetch(:copy_source)
    assert_equal "weblog-inbox-adoption=pending", @s3.api_requests[0].fetch(:params).fetch(:tagging)
    assert_equal "REPLACE", @s3.api_requests[0].fetch(:params).fetch(:tagging_directive)
    assert_equal [:copy_object], @s3.api_requests.map { |request| request.fetch(:operation_name) }
  end

  def test_rejects_a_non_photo_item
    @database.define_singleton_method(:find_inbox_item) { |_id| nil }

    assert_raises(WeblogAuthoring::ConflictError) { @inbox.prepare(item_id: "missing") }
  end

  def test_finalizes_committed_copies_and_removes_the_adoption_after_s3_succeeds
    adoption = WeblogAuthoring::InboxImageAdoption.new(
      item_id: "item-1", inbox_key: "assets/inbox/2026/08/23/photo.webp",
      public_key: "assets/uploads/2026/08/photo.webp", prepared_at: Time.now,
      committed_at: Time.now, expires_at: Time.now + 86_400
    )
    completed = []
    @database.define_singleton_method(:list_pending_inbox_image_finalizations) { |limit:| [adoption].take(limit) }
    @database.define_singleton_method(:complete_inbox_image_adoption) { |item_id:| completed << item_id }

    assert_equal 1, @inbox.finalize(limit: 10)
    assert_equal %i[put_object_tagging delete_object], @s3.api_requests.map { |request| request.fetch(:operation_name) }
    assert_empty @s3.api_requests.fetch(0).fetch(:params).fetch(:tagging).fetch(:tag_set)
    assert_equal ["item-1"], completed
  end

  def test_keeps_a_committed_adoption_retryable_when_s3_finalization_fails
    adoption = WeblogAuthoring::InboxImageAdoption.new(
      item_id: "item-1", inbox_key: "assets/inbox/2026/08/23/photo.webp",
      public_key: "assets/uploads/2026/08/photo.webp", prepared_at: Time.now,
      committed_at: Time.now, expires_at: Time.now + 86_400
    )
    completed = []
    @database.define_singleton_method(:list_pending_inbox_image_finalizations) { |limit:| [adoption].take(limit) }
    @database.define_singleton_method(:complete_inbox_image_adoption) { |item_id:| completed << item_id }
    @s3.stub_responses(:delete_object, "InternalError")

    assert_raises(Aws::S3::Errors::InternalError) { @inbox.finalize }
    assert_empty completed

    @s3.stub_responses(:delete_object, {})
    assert_equal 1, @inbox.finalize
    assert_equal ["item-1"], completed
  end
end
