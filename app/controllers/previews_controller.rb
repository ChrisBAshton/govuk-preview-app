class PreviewsController < ApplicationController
  def index
    @previews = Preview.order(created_at: :desc)
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

private

  def preview_params
    params.expect(preview: %i[app_name branch])
  end
end
