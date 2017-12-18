class Worker < ApplicationRecord
  # Include default devise modules.
  include DeviseTokenAuth::Concerns::User
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :trackable,
         authentication_keys: [:uid], case_insensitive_keys: [:uid]

  belongs_to :branch
  has_many :working_records, dependent: :destroy
  has_many :prepayment_applications, dependent: :destroy
  belongs_to :current_working_record, class_name: 'WorkingRecord', optional: true

  delegate :company, to: :branch

  has_paper_trail(
    ignore: %i[
      reset_password_token
      reset_password_sent_at
      remember_created_at
      sign_in_count
      current_sign_in_at
      last_sign_in_at
      current_sign_in_ip
      last_sign_in_ip
      updated_at
    ]
  )

  def working?
    !current_working_record.nil?
  end

  def confirmed_at
    Time.now.in_time_zone
  end

  def start_work!(start_at)
    working_record = nil
    transaction do
      working_record = WorkingRecord.create(
        start_at: start_at,
        hourly_pay: hourly_pay,
        worker: self
      )
      self.current_working_record = working_record
      save
    end
    working_record
  end

  def finish_work!(finish_at)
    working_record = current_working_record
    transaction do
      working_record.finish_at = finish_at
      working_record.calculate_payment
      working_record.save
      self.current_working_record = nil
      save
    end
    working_record
  end

  def prepayable_amount
    iteration_summary(0)[:prepayable_amount]
  end

  def apply_prepayment(amount)
    amount = amount.to_i
    raise 'prepayment not allowed' if prepayable_amount < amount
    PrepaymentApplication.create(amount: amount, worker: self)
  end

  def unpaid_amount
    last_regular_deadline_date = last_settlement_date

    prepayment_apps = PrepaymentApplication.where(worker: self)
    prepayment_apps = prepayment_apps.where('created_at > ?', last_regular_deadline_date) if last_regular_deadline_date

    working_records = WorkingRecord.where(worker: self).where.not(finish_at: nil)
    working_records = working_records.where('created_at > ?', last_regular_deadline_date) if last_regular_deadline_date

    current_applied_amount = prepayment_apps.pluck(:amount).sum
    total_to_be_earned = working_records.pluck(:payment).sum

    total_to_be_earned - current_applied_amount
  end

  def iteration_summary(diff)
    working_records = self.working_records
                          .where(start_at: company.salary_iteration(diff))
                          .where.not(finish_at: nil)
                          .order(:start_at)

    total_work_hours = working_records.map(&:hours_worked).sum
    total_salary = working_records.map(&:payment).sum

    prepayment_applications = self.prepayment_applications
                                  .where(created_at: company.salary_iteration(diff))
                                  .order(:created_at)
    total_applied = prepayment_applications.map(&:amount).sum

    salary_paid_normally = total_salary - total_applied
    prepayable_amount = salary_paid_normally * (company.prepayment_allowed_percentage / 100.0)

    { working_records: working_records,
      prepayment_applications: prepayment_applications,
      total_work_hours: total_work_hours,
      total_salary: total_salary,
      total_applied: total_applied,
      salary_paid_normally: salary_paid_normally,
      prepayable_amount: prepayable_amount }
  end
end
