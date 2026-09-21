# frozen_string_literal: true

class CreateTestTables < ActiveRecord::Migration[7.0]
  def change
    create_table :organisations do |t|
      t.string :name
      t.string :location
      t.boolean :global_admin, default: false
      t.references :parent, foreign_key: { to_table: :organisations }, null: true
      t.timestamps
    end

    create_table :accounts do |t|
      t.string :username, null: false
      t.string :password
      t.timestamps
    end
    add_index :accounts, :username, unique: true

    create_table :users do |t|
      t.references :organisation, null: false, foreign_key: true
      t.references :account, null: true, foreign_key: true
      t.string :first_name
      t.string :last_name
      t.date :date_of_birth
      t.boolean :active, default: true
      t.timestamps
    end

    create_table :emails do |t|
      t.references :account, null: true, foreign_key: true
      t.string :address, null: false
      t.timestamps
    end
    add_index :emails, :address

    create_table :phones do |t|
      t.references :account, null: true, foreign_key: true
      t.string :e164, null: false
      t.timestamps
    end

    create_table :service_industries do |t|
      t.references :organisation, null: false, foreign_key: true
      t.string :name, null: false
      t.timestamps
    end

    create_table :assets do |t|
      t.references :organisation, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.integer :status, default: 0
      t.date :manufacture_date
      t.decimal :cost, precision: 10, scale: 2
      t.date :purchase_date
      t.date :previous_service
      t.timestamps
    end

    # Join tables
    create_join_table :emails, :users do |t|
      t.index [:email_id, :user_id], unique: true
    end

    create_join_table :phones, :users do |t|
      t.index [:phone_id, :user_id], unique: true
    end

    create_join_table :service_industries, :users do |t|
      t.index [:service_industry_id, :user_id], name: "idx_si_users"
    end

    create_join_table :assets, :service_industries do |t|
      t.index [:asset_id, :service_industry_id], name: "idx_assets_si"
    end
  end
end
