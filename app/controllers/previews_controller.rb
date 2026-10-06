class PreviewsController < ApplicationController
  def index
    # Top-level only - the view nests each one's dependents (recursively)
    # beneath it via PreviewsHelper#previews_with_dependencies. Most recently
    # visited first (see HostRouter); never-visited ones last, newest first.
    @previews = Preview.where(parent_id: nil)
      .order(Arel.sql("last_accessed_at DESC NULLS LAST, created_at DESC"))
  end

  def new
    @preview = Preview.new
  end

  def create
    @preview = Preview.new(preview_params)

    if @preview.save
      PreviewsCreateJob.perform_async(@preview.id)
      redirect_to previews_path, notice: "Preview of #{@preview.app_name} (#{@preview.branch}) queued."
    else
      render :new, status: :unprocessable_content
    end
  end

  def destroy
    preview = Preview.find(params[:id])
    preview.update!(status: :stopping)
    PreviewsDestroyJob.perform_async(preview.id)

    redirect_to previews_path, notice: "Preview of #{preview.app_name} (#{preview.branch}) is being removed."
  end

  # Frees its memory for other previews - see PreviewSleeper.
  def put_to_sleep
    preview = Preview.find(params[:id])
    PreviewsSleepJob.perform_async(preview.id) if preview.running?

    redirect_to previews_path, notice: "Preview of #{preview.app_name} (#{preview.branch}) is going to sleep."
  end

  def wake
    preview = Preview.find(params[:id])
    if Preview.where(id: preview.id, status: :sleeping).update_all(status: "waking", updated_at: Time.current) == 1
      PreviewsWakeJob.perform_async(preview.id)
    end

    redirect_to previews_path, notice: "Preview of #{preview.app_name} (#{preview.branch}) is waking up."
  end

  # Adds or removes the full stack for a running preview - see
  # PreviewResizer.
  def resize
    preview = Preview.find(params[:id])
    full_stack = params[:full_stack] == "true"
    PreviewsResizeJob.perform_async(preview.id, full_stack) if preview.running? && preview.parent.blank?

    redirect_to previews_path, notice: "#{full_stack ? 'Adding' : 'Removing'} the full stack for #{preview.app_name} (#{preview.branch})."
  end

  # Carries on a failed build from where it stopped: dependencies that
  # started are reused, and only what didn't finish is built again (see
  # PreviewBuilder#build!).
  def retry_build
    preview = Preview.find(params[:id])
    if preview.failed?
      preview.update!(status: :queued, status_message: nil)
      PreviewsCreateJob.perform_async(preview.id)
    end

    redirect_to previews_path, notice: "Retrying preview of #{preview.app_name} (#{preview.branch})."
  end

private

  def preview_params
    attributes = params.expect(preview: [:app_name, :branch, { full_stack_for: {} }])
    full_stack_for = attributes.delete(:full_stack_for).to_h
    attributes.merge(full_stack: full_stack_for[attributes[:app_name]] == "true")
  end
end
