# frozen_string_literal: true

module WeblogAuthoring
  class DiaryNavigation
    DATE_ROUTE = /\A\d{4}-\d{2}-\d{2}\z/

    def initialize(database)
      @database = database
    end

    def neighbors(route)
      return { "newer" => nil, "older" => nil } unless DATE_ROUTE.match?(route)

      routes = @database.list_diary_routes.select { |candidate| DATE_ROUTE.match?(candidate) }.uniq.sort
      index = routes.index(route)
      return { "newer" => nil, "older" => nil } unless index

      { "newer" => routes[index + 1], "older" => index.positive? ? routes[index - 1] : nil }
    end
  end
end
