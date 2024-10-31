module AppQuery
  module RSpec
    module Helpers
      def default_binds
        self.class.default_binds
      end

      def expand_select(s)
        s.gsub(/:cte/, cte_name)
      end

      def select_all(select: nil, qselect: nil, binds: default_binds, **kws)
        described_query(select:, qselect:).select_all(binds:, **kws)
      end

      def select_one(select: nil, qselect: nil, binds: default_binds, **kws)
        described_query(select:, qselect:).select_one(binds:, **kws)
      end

      def described_query(select: nil, qselect: nil)
        if !qselect
          select ||= "SELECT * FROM :cte" if cte_name
        end
        select &&= expand_select(select) if cte_name
        self.class.described_query.with(select:, qselect:)
      end

      def cte_name
        self.class.cte_name
      end

      def query_name
        self.class.query_name
      end

      module ClassMethods
        def described_query
          AppQuery[query_name]
        end

        def metadatas
          scope = is_a?(Class) ? self : self.class
          metahash = scope.metadata
          result = []
          loop do
            result << metahash
            metahash = metahash[:parent_example_group]
            break unless metahash
          end
          result
        end

        def descriptions
          metadatas.map{ _1[:description] }
        end

        def query_name
          descriptions.find { _1[/(app)?query\s/i] }&.then { _1.split.last }
        end

        def cte_name
          descriptions.find { _1[/cte\s/i] }&.then { _1.split.last }
        end

        def default_binds
          metadatas.find { _1[:default_binds] }&.[](:default_binds) || []
        end

        def included(klass)
          super
          # Inject classmethods into the group.
          klass.extend(ClassMethods)
          # If the describe block is aimed at string or resource/provider class
          # then set the default subject to be the Chef run.
          # if klass.described_class.nil? || klass.described_class.is_a?(Class) && (klass.described_class < Chef::Resource || klass.described_class < Chef::Provider)
          #  klass.subject { chef_run }
          # end
        end
      end

      extend ClassMethods
    end
  end
end
