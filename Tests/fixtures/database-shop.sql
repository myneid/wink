-- Fixture for Tests/DatabaseWorkbenchChecks.swift and the Workbench's dev host.
-- mysql -h127.0.0.1 -P3306 -uroot < Tests/fixtures/database-shop.sql
DROP DATABASE IF EXISTS shop;
DROP DATABASE IF EXISTS analytics;
CREATE DATABASE shop;
CREATE DATABASE analytics;
USE shop;
CREATE TABLE customers (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100) NOT NULL, email VARCHAR(200) UNIQUE,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP, notes TEXT, avatar BLOB, balance DECIMAL(12,2) DEFAULT 0) COMMENT='People who buy things';
CREATE TABLE orders (id BIGINT AUTO_INCREMENT PRIMARY KEY, customer_id INT NOT NULL, total DECIMAL(10,2),
  status ENUM('new','paid','shipped') DEFAULT 'new', placed_at DATETIME, KEY idx_cust (customer_id),
  CONSTRAINT fk_cust FOREIGN KEY (customer_id) REFERENCES customers(id));
CREATE TABLE tags (name VARCHAR(50), color VARCHAR(10));
CREATE VIEW big_orders AS SELECT * FROM orders WHERE total > 100;
INSERT INTO customers (name, email, notes, avatar, balance) VALUES
  ('Ada', 'ada@example.com', 'first', UNHEX('89504E470D0A1A0A00FF'), 10.5),
  ('Linus', 'linus@example.com', REPEAT('long text ', 6000), NULL, 9999999999.99),
  ('Grace', 'grace@example.com', NULL, NULL, 0);
SET SESSION cte_max_recursion_depth = 5000;
INSERT INTO orders (customer_id, total, status, placed_at)
  WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM s WHERE n < 1200)
  SELECT 1 + (n % 3), n * 3.5, ELT(1 + n % 3, 'new', 'paid', 'shipped'), NOW() - INTERVAL n DAY FROM s;
INSERT INTO tags VALUES ('red', '#f00'), ('red', '#f00'), ('blue', '#00f');
CREATE TABLE analytics.events (id INT PRIMARY KEY, name VARCHAR(20));
