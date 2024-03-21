require "net/http"
require "net/https"

module ActiveMerchant
  module Billing
    module Rocketgate
      class GatewayService

        SERVLET = "/gateway/servlet/ServiceDispatcherAccess"
        CONNECT_TIMEOUT = 10
        READ_TIMEOUT = 90
        PROTOCOL = "https"
        PORTNO = "443"
        VERSION = "R3.5"
        USER_AGENT = "RG Client - Ruby #{VERSION}"
        REQUEST_HEADERS = {
          'Content-Type' => 'text/xml',
          'User-Agent' => USER_AGENT
        }

        LIVE_HOSTS = ['gateway-16.rocketgate.com', 'gateway-17.rocketgate.com']
        LIVE_HOST_16, LIVE_HOST_17 = LIVE_HOSTS

        LIVE_HOST_IPS = ['69.20.127.91', '72.32.126.131']
        LIVE_HOST_16_IP, LIVE_HOST_17_IP = LIVE_HOST_IPS

        TEST_HOST = 'dev-gateway.rocketgate.com'
        LIVE_HOST = 'gateway.rocketgate.com'

        attr_accessor :test_mode,
                      :host, :hosts, :dns, :servlet, :protocol, :port_number,
                      :connect_timeout, :read_timeout

        def initialize(test)
          self.test_mode = test
          self.servlet = SERVLET
          self.protocol = PROTOCOL
          self.port_number = PORTNO
          self.connect_timeout = CONNECT_TIMEOUT
          self.read_timeout = READ_TIMEOUT
        end

        def test_mode=(test)
          if test
            @test_mode = true
            self.hosts = [TEST_HOST]
            self.dns = TEST_HOST
          else
            @test_mode = false
            self.hosts = LIVE_HOSTS
            self.dns = LIVE_HOST
          end
        end

        def connect_timeout=(timeout)
          @connect_timeout = timeout.to_i if timeout.to_i > 0
        end

        def read_timeout=(timeout)
          @read_timeout = timeout.to_i if timeout.to_i > 0
        end

        def perform_authorization(request)
          request.transaction_type = :auth
          with_confirmation(request) { |req| perform_transaction(req) }
        end

        def perform_purchase(request)
          request.transaction_type = :purchase
          with_confirmation(request) { |req| perform_transaction(req) }
        end

        def perform_ticket(request)
          request.transaction_type = :ticket
          perform_targeted_transaction(request)
        end

        def perform_credit(request)
          request.transaction_type = :credit

          request.reference_guid.nil? ? perform_transaction(request) : perform_targeted_transaction(request)
        end

        def perform_void(request)
          request.transaction_type = :void
          perform_targeted_transaction(request)
        end

      private

        def with_confirmation(request)
          response = yield(request)
          if response.successful?
            response = perform_confirmation(request, response)
          end
          return response
        end

        def send_transaction(server_name, request)
          request_xml = request.to_xml

          connection = Net::HTTP.new(server_name, port_number)
          connection.open_timeout = connect_timeout
          connection.read_timeout = read_timeout

          # If we are doing HTTPS, we need to setup SSL.
          if (protocol.downcase == 'https')
            connection.use_ssl = true
          end

          begin
            response = connection.request_post(servlet, request_xml, REQUEST_HEADERS)
          rescue Errno::ECONNREFUSED => ex # Check if we were unable to connect.
            return ErrorResponse.new(ex.message, 301)
          rescue Timeout::Error => ex # Check if there was some type of timeout.
            return ErrorResponse.new(ex.message, 303)
          rescue => ex # Catch all other errors.
            return ErrorResponse.new(ex.message, 304)
          end

          body = response.body

          ::Rails.logger.warn { Base64.encode64(body).to_s }
          Sentry.set_context("#{self.class.name}.send_transaction", body: Base64.encode64(body).to_s)

          data = nil

          begin
            data = Hash.from_xml(body)
          rescue => e
            Sentry.capture_exception(e)
          end

          unless data && data['gatewayResponse'] && data['gatewayResponse']['responseCode']
            return ErrorResponse.new(body, 399)
          end

          return GatewayResponse.new(data['gatewayResponse'])
        end

        def perform_transaction(request)
          server_names = get_server_names.shuffle
          request.clear_failed_server

          server_names.each do |server|
            @response = send_transaction(server, request)

            if @response.successful? || @response.unrecoverable?
              return @response
            end

            request.failedServer = server
            request.failedReasonCode = @response.reasonCode
            request.failedResponseCode = @response.responseCode
            request.failedGUID = @response.guidNo
          end

          return @response
        end

        def perform_targeted_transaction(request)
          request.clear_failed_server
          reference_guid = request.reference_guid
          if reference_guid.nil?
            return ErrorResponse.new('No reference GUID specified for targeted transaction', 410)
          end

          site_string = '0x'
          if (reference_guid.length > 15)
            site_string << reference_guid[0, 2]
          else
            site_string << reference_guid[0, 1]
          end

          begin
            site_number = Integer(site_string)
          rescue => ex
            return ErrorResponse.new("Unable to convert reference GUID (#{reference_guid} into site number (#{site_string} to integer): #{ex.message}", 410)
          end

          server_name = dns
          separator = server_name.index('.')
          if (separator.present? && separator > 0)
            generated_server_name = ''
            generated_server_name << server_name[0, separator]
            generated_server_name << '-'
            generated_server_name << site_number.to_s
            generated_server_name << server_name[separator, server_name.length]
            server_name = generated_server_name
          end

          return send_transaction(server_name, request)
        end

        def perform_confirmation(request, response)
          confirm_guid = response.guidNo
          if (confirm_guid.nil?)
            return ErrorResponse.new("Missing confirmation GUID", 307)
          end

          confirm_request = GatewayConfirmation.new(request, confirm_guid)
          confirm_response = perform_targeted_transaction(confirm_request)

          if confirm_response.successful?
            return response
          else
            return confirm_response
          end
        end

        def get_server_names
          if LIVE_HOST == dns
            host_list = Resolv.getaddresses(LIVE_HOST)
            host_list.map do |host|
              case host
                when LIVE_HOST_16_IP then LIVE_HOST_16
                when LIVE_HOST_17_IP then LIVE_HOST_17
              end
            end.compact
          else
            hosts
          end
        end
      end
    end
  end
end

