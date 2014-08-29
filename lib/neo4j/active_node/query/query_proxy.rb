module Neo4j
  module ActiveNode
    module Query
      class InvalidParameterError < StandardError; end
      class QueryProxy

        include Enumerable

        def initialize(model, association = nil, options = {})
          @model = model
          @association = association
          @context = options.delete(:context)
          @options = options
          @node_var = options[:node]
          @rel_var = options[:rel] || _rel_chain_var
          @session = options[:session]
          @chain = []
          @params = options[:query_proxy] ? options[:query_proxy].instance_variable_get('@params') : {}
        end

        def identity
          @node_var || :result
        end

        def each(node = true, rel = nil, &block)
          if node && rel
            self.pluck(identity, @rel_var).each do |obj, rel|
              yield obj, rel
            end
          else
            pluck_this = !rel ? identity : @rel_var
            self.pluck(pluck_this).each do |obj|
              yield obj
            end
          end
        end

        def each_rel(&block)
          block_given? ? each(false, true, &block) : to_enum(:each, false, true)
        end

        def each_with_rel(&block)
          block_given? ? each(true, true, &block) : to_enum(:each, true, true)
        end

        def ==(value)
          self.to_a == value
        end

        METHODS = %w[where order skip limit]

        METHODS.each do |method|
          module_eval(%Q{
            def #{method}(*args)
              build_deeper_query_proxy(:#{method}, args)
            end}, __FILE__, __LINE__)
        end

        alias_method :offset, :skip
        alias_method :order_by, :order

        # For getting variables which have been defined as part of the association chain
        def pluck(*args)
          self.query.pluck(*args)
        end

        def params(params)
          self.dup.tap do |new_query|
            new_query._add_params(params)
          end
        end

        # Like calling #query_as, but for when you don't care about the variable name
        def query
          query_as(identity)
        end

        # Build a Neo4j::Core::Query object for the QueryProxy
        def query_as(var)
          var = @node_var if @node_var
          query = if @association
            chain_var = _association_chain_var
            label_string = @model && ":`#{@model.mapped_label_name}`"
            (_association_query_start(chain_var) & _query_model_as(var)).match("#{chain_var}#{_association_arrow}(#{var}#{label_string})")
          else
            _query_model_as(var)
          end

          # Build a query chain via the chain, return the result
          @chain.inject(query.params(@params)) do |query, (method, arg)|
            query.send(method, arg.respond_to?(:call) ? arg.call(var) : arg)
          end
        end

        # Cypher string for the QueryProxy's query
        def to_cypher
          query.to_cypher
        end

        # To add a relationship for the node for the association on this QueryProxy
        def <<(other_node)
          create(other_node, {})

          self
        end

        def [](index)
          # TODO: Maybe for this and other methods, use array if already loaded, otherwise
          # use OFFSET and LIMIT 1?
          self.to_a[index]
        end

        def create(other_nodes, properties)
          raise "Can only create associations on associations" unless @association
          other_nodes = [other_nodes].flatten

          other_nodes.map! do |other_node|
            case other_node
            when Integer, String
              @model.find(other_node)
            else
              other_node
            end
          end

          raise ArgumentError, "Node must be of the association's class when model is specified" if @model && other_nodes.any? {|other_node| other_node.class != @model }
          other_nodes.each do |other_node|
            #Neo4j::Transaction.run do
              other_node.save if not other_node.persisted?

              return false if @association.perform_callback(@options[:start_object], other_node, :before) == false

              start_object = @options[:start_object]
              _session.query(context: @options[:context])
                .start(start: "node(#{start_object.neo_id})", end: "node(#{other_node.neo_id})")
                .create("start#{_association_arrow(properties, true)}end").exec

              @association.perform_callback(@options[:start_object], other_node, :after)
            #end
          end
        end

        #TODO: Get these out of here
        def first
          self.order("ID(#{identity})").limit(1).pluck(identity).first
        end

        def last
          self.order("ID(#{identity}) DESC").limit(1).pluck(identity).first
        end

        # @return [Fixnum] number of nodes of this class
        def count(distinct = nil)
          raise(InvalidParameterError, ':count accepts `distinct` or nil as a parameter') unless distinct.nil? || distinct == :distinct
          q = distinct.nil? ? "n" : "DISTINCT n"
          self.query_as(:n).return("count(#{q}) AS count").first.count
        end
        alias_method :size,   :count
        alias_method :length, :count

        def empty?
          !self.exists?
        end
        alias_method :blank?, :empty?

        def include?(other)
          raise(InvalidParameterError, ':include? only accepts nodes') unless other.respond_to?(:neo_id)
          self.query_as(:n).where("ID(n) = #{other.neo_id}").return("count(n) AS count").first.count > 0
        end

        def exists?(node_id=nil)
          raise(InvalidParameterError, ':exists? only accepts neo_ids') unless node_id.is_a?(Integer) || node_id.nil?
          start_q = self.query_as(:n)
          end_q = node_id.nil? ? start_q : start_q.where("ID(n) = #{node_id}")
          end_q.return("COUNT(n) AS count").first.count > 0
        end

        # QueryProxy objects act as a representation of a model at the class level so we pass through calls
        # This allows us to define class functions for reusable query chaining or for end-of-query aggregation/summarizing
        def method_missing(method_name, *args)
          if @model && @model.respond_to?(method_name)
            call_class_method(method_name, *args)
          else
            super
          end
        end

        attr_reader :context

        protected
        # Methods are underscored to prevent conflict with user class methods

        attr_reader :node_var

        def _add_params(params)
          @params = @params.merge(params)
        end

        def _add_links(links)
          @chain += links
        end

        def _query_model_as(var)
          match_arg = if @model
            label = @model.respond_to?(:mapped_label_name) ? @model.mapped_label_name : @model
            {var => label}
          else
            var
          end
          _session.query(context: @context).match(match_arg)
        end

        def _session
          @session || (@model && @model.neo4j_session)
        end

        def _association_arrow(properties = {}, create = false)
          @association && @association.arrow_cypher(@rel_var, properties, create)
        end

        def _chain_level
          if @options[:start_object]
            1
          elsif query_proxy = @options[:query_proxy]
            query_proxy._chain_level + 1
          else
            1
          end
        end

        def _association_chain_var
          if start_object = @options[:start_object]
            :"#{start_object.class.name.gsub('::', '_').downcase}#{start_object.neo_id}"
          elsif query_proxy = @options[:query_proxy]
            query_proxy.node_var || :"node#{_chain_level}"
          else
            raise "Crazy error" # TODO: Better error
          end
        end

        def _association_query_start(var)
          if start_object = @options[:start_object]
            start_object.query_as(var)
          elsif query_proxy = @options[:query_proxy]
            query_proxy.query_as(var)
          else
            raise "Crazy error" # TODO: Better error
          end
        end

        def _rel_chain_var
          :"rel#{_chain_level - 1}"
        end

        attr_writer :context

        private

        def call_class_method(method_name, *args)
          args[2] = self
          result = @model.send(method_name, *args)
          result
        end

        def build_deeper_query_proxy(method, args)
          self.dup.tap do |new_query|
            args.each do |arg|
              new_query._add_links(links_for_arg(method, arg))
            end
          end
        end

        def links_for_arg(method, arg)
          method_to_call = "links_for_#{method}_arg"

          default = [[method, arg]]

          self.send(method_to_call, arg) || default
        rescue NoMethodError
          default
        end

        def links_for_where_arg(arg)
          node_num = 1
          result = []
          if arg.is_a?(Hash)
            arg.map do |key, value|
              if @model && @model.has_association?(key)

                neo_id = value.try(:neo_id) || value
                raise ArgumentError, "Invalid value for '#{key}' condition" if not neo_id.is_a?(Integer)

                n_string = "n#{node_num}"
                dir = @model.associations[key].direction

                arrow = dir == :out ? '-->' : '<--'
                result << [:match, ->(v) { "#{v}#{arrow}(#{n_string})" }]
                result << [:where, ->(v) { {"ID(#{n_string})" => neo_id.to_i} }]
                node_num += 1
              else
                result << [:where, ->(v) { {v => {key => value}}}]
              end
            end
          elsif arg.is_a?(String)
            result << [:where, arg]
          end
          result
        end

        def links_for_order_arg(arg)
          [[:order, ->(v) { arg.is_a?(String) ? arg : {v => arg} }]]
        end


      end

    end
  end
end

