require 'nori'

module WashOut
  # This class is a Rack middleware used to route SOAP requests to a proper
  # action of a given SOAP controller.
  class Router
    def initialize(controller_name)
      @controller_name = "#{controller_name.to_s}_controller".camelize
    end

    def controller
      @controller
    end

    def parse_soap_action(env)
      return env['wash_out.soap_action'] if env['wash_out.soap_action']

      soap_action = controller.soap_config.soap_action_routing ? env['HTTP_SOAPACTION'].to_s.gsub(/^"(.*)"$/, '\1')
                                                               : ''

      if soap_action.blank?
        parsed_soap_body = nori(controller.soap_config.snakecase_input).parse(soap_body env)
        return nil if parsed_soap_body.blank?

        soap_action = parsed_soap_body.values_at(:envelope, :Envelope).try(:compact).try(:first)
        soap_action = soap_action.values_at(:body, :Body).try(:compact).try(:first) if soap_action
        soap_action = soap_action.keys.first.to_s if soap_action
      end

      # RUBY18 1.8 does not have force_encoding.
      soap_action.force_encoding('UTF-8') if soap_action.respond_to? :force_encoding

      if controller.soap_config.namespace
        namespace = Regexp.escape controller.soap_config.namespace.to_s
        soap_action.gsub!(/^(#{namespace}(\/|#)?)?([^"]*)$/, '\3')
      end

      env['wash_out.soap_action'] = soap_action
    end

    def nori(snakecase=false)
      Nori.new(
        :parser => controller.soap_config.parser,
        :strip_namespaces => true,
        :advanced_typecasting => true,
        :convert_tags_to => (
          snakecase ? lambda { |tag| tag.snakecase.to_sym }
                    : lambda { |tag| tag.to_sym }
        )
      )
    end

    def soap_body(env)
      body = env['rack.input']
      body.rewind if body.respond_to? :rewind
      body.respond_to?(:string) ? body.string : body.read
    ensure
      body.rewind if body.respond_to? :rewind
    end

    def parse_soap_parameters(env)
      return env['wash_out.soap_data'] if env['wash_out.soap_data']
      env['wash_out.soap_data'] = nori(controller.soap_config.snakecase_input).parse(soap_body env)
      references = WashOut::Dispatcher.deep_select(env['wash_out.soap_data']){|v| v.is_a?(Hash) && v.has_key?(:@id)}

      unless references.blank?
        replaces = {}; references.each{|r| replaces['#'+r[:@id]] = r}
        env['wash_out.soap_data'] = WashOut::Dispatcher.deep_replace_href(env['wash_out.soap_data'], replaces)
      end

      env['wash_out.soap_data']
    end

    def call(env)
      @controller = @controller_name.constantize

      soap_action = parse_soap_action(env)

      action = if soap_action.blank?
        '_invalid_request'
      else
        soap_parameters = parse_soap_parameters(env)
        action_spec     = controller.soap_actions[soap_action]

        if action_spec
          action_spec[:to]
        else
          '_invalid_action'
        end
      end

      controller.action(action).call(env)
    end
  end
end
