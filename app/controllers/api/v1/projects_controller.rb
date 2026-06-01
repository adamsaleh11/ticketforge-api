module Api
  module V1
    class ProjectsController < ApplicationController
      # GET /api/v1/projects
      def index
        projects = current_user.projects.order(created_at: :desc)
        render json: ProjectSerializer.new(projects).serializable_hash
      end

      # GET /api/v1/projects/:id
      def show
        render json: ProjectSerializer.new(find_project).serializable_hash
      end

      # POST /api/v1/projects
      def create
        project = current_user.projects.new(project_params)
        if project.save
          render json: ProjectSerializer.new(project).serializable_hash, status: :created
        else
          render_validation_errors(project)
        end
      end

      # PATCH /api/v1/projects/:id
      def update
        project = find_project
        if project.update(project_params)
          render json: ProjectSerializer.new(project).serializable_hash
        else
          render_validation_errors(project)
        end
      end

      # DELETE /api/v1/projects/:id
      def destroy
        find_project.destroy
        head :no_content
      end

      private

      # Always scope through the association so another user's (or a missing)
      # project raises RecordNotFound -> 404, never leaking existence.
      def find_project
        current_user.projects.find(params[:id])
      end

      def project_params
        # status is lifecycle-driven and set internally by the TicketGenerator
        # service (Phase 5). Never permit it through controller params.
        # user_id is owned by the current_user association, never client-set.
        params.require(:project).permit(
          :name, :description, :github_repo_full_name, :llm_provider, :llm_model
        )
      end
    end
  end
end
