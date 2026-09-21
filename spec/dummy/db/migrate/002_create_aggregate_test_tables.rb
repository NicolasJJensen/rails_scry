# frozen_string_literal: true

class CreateAggregateTestTables < ActiveRecord::Migration[7.0]
  def change
    create_table :technicians do |t|
      t.string :name, null: false
      t.integer :max_daily_hours, default: 8
      t.boolean :active, default: true
      t.text :skills, array: true, default: []
      t.text :certifications, array: true, default: []
      t.jsonb :work_hours, default: {}
      t.timestamps
    end

    create_table :jobs do |t|
      t.string :title, null: false
      t.integer :duration_hours, default: 1
      t.integer :priority, default: 1
      t.integer :crew_size, default: 1
      t.timestamps
    end

    create_table :schedule_assignments do |t|
      t.references :technician, null: false, foreign_key: true
      t.references :job, null: false, foreign_key: true
      t.datetime :scheduled_start
      t.datetime :scheduled_end
      t.integer :travel_time_minutes, default: 0
      t.decimal :travel_distance_km, precision: 10, scale: 2, default: 0
      t.timestamps
    end
  end
end
