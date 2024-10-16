module AppQuery
  class Configuration
    attr_accessor :query_path

    def initialize
      @query_path = "app/queries"
    end
  end
end
