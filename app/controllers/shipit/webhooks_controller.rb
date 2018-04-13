module Shipit
  class WebhooksController < ActionController::Base
    before_action :check_if_ping, :verify_signature

    respond_to :json

    class Handler
      class << self
        attr_reader :param_parser

        def params(&block)
          @param_parser = ExplicitParameters::Parameters.define(&block)
        end
      end

      attr_reader :params, :payload

      def initialize(payload)
        @payload = payload
        @params = self.class.param_parser.parse!(payload)
      end

      def process
        raise NotImplementedError
      end

      private

      def stacks
        @stacks ||= Stack.repo(repository_name)
      end

      def repository_name
        payload.dig('repository', 'full_name')
      end
    end

    class PushHandler < Handler
      params do
        requires :ref
      end
      def process
        stacks.where(branch: branch).each(&:sync_github)
      end

      private

      def branch
        params.ref.gsub('refs/heads/', '')
      end
    end

    class StatusHandler < Handler
      params do
        requires :sha, String
        requires :state, String
        accepts :description, String
        accepts :target_url, String
        accepts :context, String
        accepts :created_at, String

        accepts :branches, Array do
          requires :name, String
        end
      end
      def process
        Commit.where(sha: params.sha).each do |commit|
          commit.create_status_from_github!(params)
        end
      end
    end

    class MembershipHandler < Handler
      params do
        requires :team do
          requires :id, Integer
          requires :name, String
          requires :slug, String
          requires :url, String
        end
        requires :organization do
          requires :login, String
        end
        requires :member do
          requires :login, String
        end
      end
      def process
        team = find_or_create_team!
        member = User.find_or_create_by_login!(params.member.login)

        case action
        when 'added'
          team.add_member(member)
        when 'removed'
          team.members.delete(member)
        else
          raise ArgumentError, "Don't know how to perform action: `#{action.inspect}`"
        end
      end

      private

      def find_or_create_team!
        Team.find_or_create_by!(github_id: params.team.id) do |team|
          team.github_team = params.team
          team.organization = params.organization.login
          team.automatically_setup_hooks = true
        end
      end

      def action
        # GitHub send an `action` parameter that is shadowed by Rails url parameters
        # It's also impossible to pass an `action` parameters from a test case.
        params[:_action] || params[:action]
      end
    end

    HANDLERS = {
      'push' => PushHandler,
      'status' => StatusHandler,
      'membership' => MembershipHandler,
    }.freeze

    def create
      if handler = HANDLERS[event]
        handler.new(request.parameters).process
      end

      head :ok
    end

    private

    def verify_signature
      head(422) unless Shipit.github.verify_webhook_signature(request.headers['X-Hub-Signature'], request.raw_post)
    end

    def check_if_ping
      head :ok if event == 'ping'
    end

    def event
      request.headers.fetch('X-Github-Event')
    end

    def stack
      @stack ||= Stack.find(params[:stack_id])
    end
  end
end
