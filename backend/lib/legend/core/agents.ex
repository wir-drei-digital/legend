defmodule Legend.Core.Agents do
  @moduledoc """
  Agent sessions domain: session records, their lifecycle actions, and the
  JSON:API surface at /api/sessions.
  """

  use Ash.Domain, otp_app: :legend, extensions: [AshJsonApi.Domain]

  json_api do
    routes do
      base_route "/sessions", Legend.Core.Agents.Session do
        index :list
        get :read
        post :start
        patch :resume, route: "/:id/resume"
        delete :destroy
      end
    end
  end

  resources do
    resource Legend.Core.Agents.Session do
      define :start_session, action: :start
      define :list_sessions, action: :list
      define :get_session, action: :read, get_by: [:id]
      define :get_session_by_token, action: :by_token, args: [:token]
      define :mark_session_provisioning, action: :mark_provisioning
      define :mark_session_running, action: :mark_running
      define :finish_session, action: :finish
      define :fail_session, action: :fail
      define :interrupt_session, action: :interrupt
      define :resume_session, action: :resume
      define :destroy_session, action: :destroy
    end
  end
end
