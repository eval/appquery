# frozen_string_literal: true

require "active_support/concern"

module AppQuery
  # Middleware concern that adds pagination support to {BaseQuery} subclasses.
  #
  # Include this module in your query class to enable pagination with
  # Kaminari-compatible result objects.
  #
  # Provides two modes:
  # - **With count**: Full pagination with page numbers (uses COUNT query)
  # - **Without count**: Simple prev/next for large datasets (uses limit+1 trick)
  #
  # @note This is a {BaseQuery} middleware. Include it in classes that inherit
  #   from {BaseQuery} and use the +paginate+ ERB helper in your SQL template.
  #
  # @see BaseQuery Base class for query objects
  # @see Mappable Another middleware for mapping results to objects
  #
  # @example Basic usage
  #   class ApplicationQuery < AppQuery::BaseQuery
  #     include AppQuery::Paginatable
  #     per_page 50
  #   end
  #
  #   class ArticlesQuery < ApplicationQuery
  #     per_page 10
  #   end
  #
  #   # With count (full pagination)
  #   articles = ArticlesQuery.new.paginate(page: 1).entries
  #   articles.total_pages  # => 5
  #   articles.current_page # => 1
  #
  #   # Without count (large datasets)
  #   articles = ArticlesQuery.new.paginate(page: 1, without_count: true).entries
  #   articles.next_page    # => 2 (or nil if last page)
  #
  # @example SQL template with pagination
  #   -- app/queries/articles.sql
  #   SELECT * FROM articles
  #   ORDER BY published_on DESC
  #   <%= paginate(page: page, per_page: per_page) %>
  module Paginatable
    extend ActiveSupport::Concern

    # Kaminari-compatible wrapper for paginated results.
    #
    # Wraps an array of records with pagination metadata, providing a consistent
    # interface for both counted and uncounted pagination modes.
    #
    # Includes Enumerable, so all standard iteration methods work directly.
    #
    # @example
    #   result = ArticlesQuery.new.paginate(page: 2).entries
    #   result.each { |article| puts article["title"] }
    #   result.current_page # => 2
    #   result.total_pages  # => 5
    class PaginatedResult
      include Enumerable

      delegate :each, :size, :[], :empty?, :first, :last, to: :@records

      # @api private
      def initialize(records, page:, per_page:, total_count: nil, has_next: nil)
        @records = records
        @page = page
        @per_page = per_page
        @total_count = total_count
        @has_next = has_next
      end

      # @return [Integer] the current page number
      def current_page = @page

      # @return [Integer] the number of records per page
      def limit_value = @per_page

      # @return [Integer, nil] the previous page number, or nil if on first page
      def prev_page = (@page > 1) ? @page - 1 : nil

      # @return [Boolean] true if this is the first page
      def first_page? = @page == 1

      # @return [Integer] the total number of records across all pages
      # @raise [RuntimeError] if called in +without_count+ mode
      def total_count
        @total_count || raise("total_count not available in without_count mode")
      end

      # @return [Integer, nil] the total number of pages, or nil in +without_count+ mode
      def total_pages
        return nil unless @total_count
        (@total_count.to_f / @per_page).ceil
      end

      # @return [Integer, nil] the next page number, or nil if on last page
      def next_page
        if @total_count
          (@page < total_pages) ? @page + 1 : nil
        else
          @has_next ? @page + 1 : nil
        end
      end

      # @return [Boolean] true if this is the last page
      def last_page?
        if @total_count
          @page >= total_pages
        else
          !@has_next
        end
      end

      # @return [Boolean] true if the requested page is beyond available data
      def out_of_range?
        empty? && @page > 1
      end

      # Transforms each record in place using the given block.
      #
      # @yield [record] Block to transform each record
      # @yieldparam record [Hash] the record to transform
      # @yieldreturn [Object] the transformed record
      # @return [self] for chaining
      #
      # @example
      #   result.transform! { |row| OpenStruct.new(row) }
      def transform!
        @records = @records.map { |r| yield(r) }
        self
      end
    end

    included do
      var :page, default: nil
      var :per_page, default: -> { self.class.per_page }
    end

    class_methods do
      # Gets or sets the default number of records per page.
      #
      # When called without arguments, returns the current per_page value
      # (inheriting from superclass if not set, defaulting to 25).
      #
      # @param value [Integer, nil] the number of records per page (setter)
      # @return [Integer] the current per_page value (getter)
      #
      # @example
      #   class ArticlesQuery < ApplicationQuery
      #     per_page 10
      #   end
      #
      #   ArticlesQuery.per_page # => 10
      def per_page(value = nil)
        if value.nil?
          return @per_page if defined?(@per_page)
          superclass.respond_to?(:per_page) ? superclass.per_page : 25
        else
          @per_page = value
        end
      end
    end

    # Enables pagination for this query.
    #
    # @param page [Integer] page number, starting at 1
    # @param per_page [Integer] records per page (defaults to class setting)
    # @param without_count [Boolean] skip COUNT query for large datasets
    # @return [self] for chaining
    #
    # @example Standard pagination with total count
    #   ArticlesQuery.new.paginate(page: 2, per_page: 20).entries
    #
    # @example Fast pagination without count (for large tables)
    #   ArticlesQuery.new.paginate(page: 1, without_count: true).entries
    def paginate(page: 1, per_page: self.class.per_page, without_count: false)
      @page = page
      @per_page = per_page
      @without_count = without_count
      self
    end

    # Disables pagination, returning all results.
    #
    # @return [self] for chaining
    #
    # @example
    #   ArticlesQuery.new.unpaginated.entries # => all records
    def unpaginated
      @page = nil
      @per_page = nil
      self
    end

    # Executes the query and returns paginated results.
    #
    # @return [PaginatedResult] when pagination is enabled
    # @return [Array<Hash>] when unpaginated
    def entries
      @_entries ||= build_paginated_result(super)
    end

    # Returns the total count of records (without pagination).
    #
    # Executes a separate COUNT query. Result is memoized.
    #
    # @return [Integer] total number of records
    def total_count
      @_total_count ||= unpaginated_query.count
    end

    private

    # Returns the underlying query without pagination applied.
    #
    # Useful for getting total counts or building derived queries.
    #
    # @return [AppQuery::Q] the unpaginated query object
    def unpaginated_query
      base_query
        .render(**render_vars, page: nil)
        .with_binds(**bind_vars)
    end


    def build_paginated_result(entries)
      return entries unless @page # No pagination requested

      if @without_count
        has_next = entries.size > @per_page
        records = has_next ? entries.first(@per_page) : entries
        PaginatedResult.new(records, page: @page, per_page: @per_page, has_next: has_next)
      else
        PaginatedResult.new(entries, page: @page, per_page: @per_page, total_count: total_count)
      end
    end

    def render_vars
      vars = super
      # Fetch one extra row in without_count mode to detect if there's more
      if @without_count && vars[:per_page]
        vars = vars.merge(per_page: vars[:per_page] + 1)
      end
      vars
    end
  end
end
