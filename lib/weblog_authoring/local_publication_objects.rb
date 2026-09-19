# frozen_string_literal: true

require "fileutils"
require "stringio"
require "aws-sdk-s3"

module WeblogAuthoring
  class LocalPublicationObjects
    ObjectResponse = Data.define(:body)

    def initialize(root)
      @root = Pathname(root)
    end

    def get_object(bucket:, key:, response_target: nil)
      data = @root.join(bucket, key).binread
      File.binwrite(response_target, data) if response_target
      ObjectResponse.new(body: StringIO.new(data))
    rescue Errno::ENOENT
      raise Aws::S3::Errors::NoSuchKey.new(nil, "missing publication object")
    end

    def put_object(bucket:, key:, body:, if_none_match: nil, **)
      path = @root.join(bucket, key)
      FileUtils.mkdir_p(path.dirname)
      body = body.read if body.respond_to?(:read)
      temporary = path.sub_ext(".#{SecureRandom.hex(8)}.tmp")
      temporary.binwrite(body)
      if if_none_match == "*"
        File.link(temporary, path)
      else
        File.rename(temporary, path)
      end
      nil
    rescue Errno::EEXIST
      raise Aws::S3::Errors::PreconditionFailed.new(nil, "already placed")
    ensure
      File.unlink(temporary) if temporary && temporary.exist?
    end
  end
end
