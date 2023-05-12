# This is landing page the first page which customer see and before visit it he often have no account with us.
# We parse and decrypt token from lead system sent with redirect to this page and set  @attrs with attributes. 
# using  @attrs[:customer_id] @attrs[:loan_id] @attrs[:lead_id] we pull information from 3rd party API about Customer and Loan Application and save them into DB.
# After we pull all agreement HTMLS by #process_conditional_loan_agreement method and it is very slow 5 seconds to execute for only one purpose to extract loan amount from agreement and show it on landing page and you can't improve it because it depends on 3rd party. 
 
# So your tasks are:
# 1. Improve readability to easy understanding by any new developer who will see that first time
# 2. Improve testability and reduce cyclomatic complexity  
# 3. You need to change architecture to speed up page within 5 seconds and still show loan amount to customer in some different way.  

def lead_conditional_loan_agreement
    redirect_to loan_application_current_path and return if user_signed_in?

    inf_customer_id = @attrs[:customer_id]
    inf_loan_id     = @attrs[:loan_id]
    loan            = Infinity::InstallmentLoan.fetch inf_loan_id, inf_customer_id
    current_user = User.find_by_infinity_customer_id(inf_customer_id)

    # DEV-147
    if loan && loan.creation_timestamp < LEADS_EXPIRE_IN.days.ago
      redirect_to new_user_session_path, alert: I18n.t('please_login') and return
    end

    if current_user
      process_user_application(current_user, inf_loan_id, inf_customer_id)
    else
      current_user = find_user(inf_customer_id, loan, inf_customer_id, inf_loan_id)
    end

    sign_in(current_user)
    @loan_app = current_user.loan_application

    if @loan_app.should_be_in_manual_review?
      redirect_to(send_to_manual_review(@loan_app)[:redirect_to])
    end

    check_declined_credit(@loan_app)
    check_preapproved_offer(current_user, @loan_app)

    UpdateInfinityWithCreditReportsJob.perform_later(inf_customer_id, inf_loan_id,  @attrs[:lead_id])
    run_no_ibv_installment_check(@loan_app)

    #process_conditional_loan_agreement(loan, @loan_app); return if performed?
    conditional_loan_agreement = Rails.cache.fetch(loan.id.to_s + @loan_app.id.to_s, expires_in: 1.day) do
      process_conditional_loan_agreement(loan, @loan_app)
    end

    generate_loan_conditional_agreement(conditional_loan_agreement, loan, @loan_app); return if performed?  
    
    render(:conditional_landing_page)
  end

  private 

  def check_declined_credit(@loan_app)
    redirect_to(loan_application_current_path) and return if @loan_app.declined_credit?
  end


  def check_preapproval_offer
    if !!current_user.active_preapproval_offer
      @preapproval_offer = true
      @loan_app.update_attributes(offer: current_user.active_preapproval_offer)
    end
  end

  def process_user_application(current_user, inf_loan_id, inf_customer_id)
    loan_application = current_user.loan_applications.where(infinity_loan_id: inf_loan_id).last

    if loan_application
      loan_application.update! ip_address: request.remote_ip
    elsif !LoanApplication.where(infinity_loan_id: inf_loan_id).exists?
      inf_customer = @client.get_customer inf_customer_id
      LoanApplicationManager.create_loan_application_for_user(current_user, inf_customer, loan, @attrs[:lead_id], request.remote_ip)
    else
      found_loan_app = LoanApplication.where(infinity_loan_id: inf_loan_id).last
      found_user = found_loan_app.user
      logger.warn("Found account duplicate: #{found_user.email} with infinity_loan_id:#{found_loan_app.infinity_loan_id} for lead: #{@attrs[:lead_id]}, current_user: #{current_user.email}")
      login_method = found_user.email
      login_hint = I18n.t('please_login_with', login_method: login_method)
      session_set_key_value('login_hint', login_hint)
      redirect_to new_user_session_path, alert: login_hint and return
    end
  end

  def find_user(inf_customer_id, loan, inf_customer_id, inf_loan_id)
    begin
      current_user = LoanApplicationManager.find_or_create_user_with_loan_application! inf_customer_id, loan[:id], @attrs[:lead_id], request.remote_ip, inf_loan: loan
      ahoy.track "lead", page: 'lead_conditional_loan_agreement',
                         infinity_customer_id: inf_customer_id,
                         infinity_loan_id: inf_loan_id,
                         lead_id:  @attrs[:lead_id]
    rescue ActiveRecord::RecordInvalid => e
      return redirect_to(new_user_session_path, :alert => I18n.t('problem_creating'))
    end
  end