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
        VERSION = "R3.0"
        USER_AGENT = "RG Client - Ruby #{VERSION}"
        REQUEST_HEADERS = {
          'Content-Type' => 'text/xml',
          'User-Agent' => USER_AGENT
        }

        LIVE_HOST = 'secure.rocketgate.com'
        TEST_HOST = 'dev-secure.rocketgate.com'

        attr_accessor :test_mode,
                      :host, :servlet, :protocol, :port_number,
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
            self.host = TEST_HOST
          else
            @test_mode = false
            self.host = LIVE_HOST
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
          perform_transaction(request)
        end

        def perform_credit(request)
          request.transaction_type = :credit
          perform_transaction(request)
        end

        def perform_void(request)
          request.transaction_type = :void
          perform_transaction(request)
        end

      private

        def with_confirmation(request)
          response = yield(request)
          if response.successful?
            response = perform_confirmation(request, response)
          end
          return response
        end

        def send_transaction(request)
          request_xml = request.to_xml

          connection = Net::HTTP.new(host, port_number)
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
          Sentry.set_context("#{self.class.name}.send_transaction", body:Base64.encode64(body).to_s)

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
          request.clear_failed_server

          response = send_transaction(request)

          if response.successful?
            return response
          elsif response.unrecoverable?
            return response
          end

          request.failedServer = host
          request.failedReasonCode = response.reasonCode
          request.failedResponseCode = response.responseCode
          request.failedGUID = response.guidNo

          return response
        end

        def perform_confirmation(request, response)
          confirm_guid = response.guidNo
          if (confirm_guid.nil?)
            return ErrorResponse.new("Missing confirmation GUID", 307)
          end

          confirm_request = GatewayConfirmation.new(request, confirm_guid)
          confirm_request.clear_failed_server

          confirm_response = send_transaction(confirm_request)

          if confirm_response.successful?
            return response
          else
            return confirm_response
          end
        end
      end
    end
  end
end
