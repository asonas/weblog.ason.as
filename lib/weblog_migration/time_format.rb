# frozen_string_literal: true

require "time"

module WeblogMigration
  module TimeFormat
    module_function

    def iso8601(value)
      value.utc.iso8601(6).sub(".000000+00:00", "+00:00").sub(/Z\z/, "+00:00")
    end
  end
end
