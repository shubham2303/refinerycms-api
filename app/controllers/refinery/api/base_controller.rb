require_dependency 'refinery/api/controller_setup'

module Refinery
  module Api
    class BaseController < ActionController::Base
      include Refinery::Api::ControllerSetup
      include Refinery::Api::ControllerHelpers::StrongParameters

      attr_accessor :current_api_user

      before_action :set_content_type
      before_action :load_user
      before_action :authorize_for_order, if: Proc.new { order_token.present? }
      before_action :authenticate_user
      before_action :load_user_roles

      rescue_from ActionController::ParameterMissing, with: :error_during_processing
      rescue_from ActiveRecord::RecordInvalid, with: :error_during_processing
      rescue_from ActiveRecord::RecordNotFound, with: :not_found
      rescue_from CanCan::AccessDenied, with: :unauthorized
      rescue_from Refinery::Api::GatewayError, with: :gateway_error

      helper Refinery::Api::ApiHelpers

      def map_nested_attributes_keys(klass, attributes)
        nested_keys = klass.nested_attributes_options.keys
        attributes.inject({}) do |h, (k,v)|
          key = nested_keys.include?(k.to_sym) ? "#{k}_attributes" : k
          h[key] = v
          h
        end.with_indifferent_access
      end

      # users should be able to set price when importing orders via api
      def permitted_line_item_attributes
        if @current_user_roles.include?("admin")
          super + [:price, :variant_id, :sku]
        else
          super
        end
      end

      def content_type
        case params[:format]
        when "json"
          "application/json; charset=utf-8"
        when "xml"
          "text/xml; charset=utf-8"
        end
      end

      protected

      def authorisation_manager
        @authorisation_manager ||= ::Refinery::Core::AuthorisationManager.new
      end
      # We ❤ you, too ️
      alias_method :authorization_manager, :authorisation_manager

      private

      def set_content_type
        headers["Content-Type"] = content_type
      end

      def load_user
        @current_api_user = Refinery::Api.user_class.find_by(refinery_api_key: api_key.to_s)
      end

      def authenticate_user
        return if @current_api_user

        if requires_authentication? && api_key.blank? && order_token.blank?
          render "refinery/api/errors/must_specify_api_key", status: 401 and return
        elsif order_token.blank? && (requires_authentication? || api_key.present?)
          render "refinery/api/errors/invalid_api_key", status: 401 and return
        else
          # An anonymous user
          @current_api_user = Refinery::Api.user_class.new
        end
      end

      def load_user_roles
        @current_user_roles = @current_api_user ? @current_api_user.roles.pluck(:title) : []
      end

      def unauthorized
        render "refinery/api/errors/unauthorized", status: 401 and return
      end

      def error_during_processing(exception)
        Rails.logger.error exception.message
        Rails.logger.error exception.backtrace.join("\n")

        unprocessable_entity(exception.message)
      end

      def unprocessable_entity(message)
        render text: { exception: message }.to_json, status: 422
      end

      def gateway_error(exception)
        @order.errors.add(:base, exception.message)
        invalid_resource!(@order)
      end

      def requires_authentication?
        Refinery::Api.requires_authentication
      end

      def not_found
        render "refinery/api/errors/not_found", status: 404 and return
      end

      def current_ability
        Refinery::Ability.new(current_api_user)
      end

      def invalid_resource!(resource)
        @resource = resource
        render "refinery/api/errors/invalid_resource", status: 422
      end

      def api_key
        request.headers["X-Refinery-Token"] || params[:token]
      end
      helper_method :api_key

      def order_token
        request.headers["X-Refinery-Order-Token"] || params[:order_token]
      end

      def find_product(id)
        product_scope.friendly.find(id.to_s)
      rescue ActiveRecord::RecordNotFound
        product_scope.find(id)
      end

      def product_scope
        if @current_user_roles.include?("admin")
          scope = Product.with_deleted.accessible_by(current_ability, :read).includes(*product_includes)

          unless params[:show_deleted]
            scope = scope.not_deleted
          end
          unless params[:show_discontinued]
            scope = scope.not_discontinued
          end
        else
          scope = Product.accessible_by(current_ability, :read).active.includes(*product_includes)
        end

        scope
      end

      def variants_associations
        [{ option_values: :option_type }, :default_price, :images]
      end

      def product_includes
        [:option_types, :taxons, product_properties: :property, variants: variants_associations, master: variants_associations]
      end

      def order_id
        params[:order_id] || params[:checkout_id] || params[:order_number]
      end

      def authorize_for_order
        @order = Refinery::Order.find_by(number: order_id)
        authorize! :read, @order, order_token
      end
    end
  end
end
