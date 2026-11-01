/*
   DIALER ANALYTICS  -  01_import_raw.sql  (SQL Server)
   Task: Create the database, create the [raw] schema, create 6 tables, and load 6 CSV files.

   BEFORE RUNNING:
    - Extract dialer_data_raw.zip to C:\dialer-analytics\data_raw\
    - Update @folder below if you use a different directory.
*/

IF DB_ID('DialerDB') IS NULL CREATE DATABASE DialerDB;
GO

USE DialerDB;
GO

-- Schema raw:
IF SCHEMA_ID('raw') IS NULL EXEC ('CREATE SCHEMA [raw]');
GO

-- Create raw tables: nvarchar() data type:
DROP TABLE IF EXISTS [raw].leads, [raw].call_log, [raw].agents, [raw].campaigns, [raw].dnc_list, [raw].agent_daily;
GO

CREATE TABLE [raw].leads (
    lead_id NVARCHAR(50), full_name NVARCHAR(100), phone NVARCHAR(50), source NVARCHAR(50),
    province NVARCHAR(50), age NVARCHAR(20), income_band NVARCHAR(20), campaign_id NVARCHAR(20),
    import_date NVARCHAR(30)
);
CREATE TABLE [raw].call_log (
    call_id NVARCHAR(50), lead_id NVARCHAR(50), agent_id NVARCHAR(50), campaign_id NVARCHAR(20),
    dialer_mode NVARCHAR(30), call_start NVARCHAR(30), attempt_no NVARCHAR(10), call_result NVARCHAR(50),
    ring_sec NVARCHAR(20), wait_sec NVARCHAR(20), talk_sec NVARCHAR(20), hold_sec NVARCHAR(20),
    wrap_sec NVARCHAR(20)
);
CREATE TABLE [raw].agents (
    agent_id NVARCHAR(50), agent_name NVARCHAR(100), team_id NVARCHAR(20), campaign_id NVARCHAR(20),
    team_leader NVARCHAR(20), hire_date NVARCHAR(30)
);
CREATE TABLE [raw].campaigns (
    campaign_id NVARCHAR(20), campaign_name NVARCHAR(100), product NVARCHAR(50), dialer_mode NVARCHAR(30),
    max_attempts NVARCHAR(10), call_window_start NVARCHAR(10), call_window_end NVARCHAR(10),
    abandon_threshold NVARCHAR(10)
);
CREATE TABLE [raw].dnc_list (
    phone NVARCHAR(50), added_date NVARCHAR(30), reason NVARCHAR(100)
);
CREATE TABLE [raw].agent_daily (
    agent_id NVARCHAR(50), work_date NVARCHAR(30), login_sec NVARCHAR(20), break_sec NVARCHAR(20),
    busy_sec NVARCHAR(20), idle_sec NVARCHAR(20)
);
GO

-- Import data to table:
DECLARE @folder NVARCHAR(400) = N'D:\Charles (Viet Cuong) Phan\DA Portfolio Projects\dialer_analytics\data_raw\';
 
DECLARE @map TABLE (tbl SYSNAME, f NVARCHAR(100));
INSERT @map VALUES ('leads','leads_raw.csv'), ('call_log','call_log_raw.csv'), ('agents','agents.csv'),
                   ('campaigns','campaigns.csv'), ('dnc_list','dnc_list.csv'), ('agent_daily','agent_daily.csv');
 
DECLARE @tbl SYSNAME, @f NVARCHAR(100), @sql NVARCHAR(MAX);
DECLARE @b VARBINARY(MAX), @head VARBINARY(4000), @term NVARCHAR(10);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT tbl, f FROM @map;
OPEN c;
FETCH NEXT FROM c INTO @tbl, @f;
WHILE @@FETCH_STATUS = 0
BEGIN
    -- doc file thanh 1 khoi nhi phan (khong can biet cau truc cot)
    SET @sql = N'SELECT @out = BulkColumn FROM OPENROWSET(BULK ''' + @folder + @f + N''', SINGLE_BLOB) AS x;';
    EXEC sp_executesql @sql, N'@out VARBINARY(MAX) OUTPUT', @out = @b OUTPUT;
    SET @head = SUBSTRING(@b, 1, 4000);
 
    SET @term = CASE WHEN CHARINDEX(0x0D0A, @head) > 0 THEN N'\r\n'    -- Windows (CRLF)
                     WHEN CHARINDEX(0x0A,   @head) > 0 THEN N'0x0a'    -- Linux/Mac (LF)
                     WHEN CHARINDEX(0x0D,   @head) > 0 THEN N'0x0d'    -- CR
                     ELSE N'0x0a' END;
 
    PRINT 'Dang nap: ' + @tbl + ' | 16 byte dau: ' + CONVERT(VARCHAR(40), SUBSTRING(@b, 1, 16), 1)
          + ' | row terminator: ' + @term;
    IF SUBSTRING(@b, 1, 2) IN (0xFFFE, 0xFEFF)
        PRINT '  !! File la UTF-16 (da bi luu lai bang chuong trinh khac). Hay dung file goc UTF-8 trong zip.';
 
    -- Khong dung FORMAT='CSV'/CODEPAGE: du lieu toan ASCII, khong co dau nhay/dau phay trong gia tri
    SET @sql = N'BULK INSERT [raw].' + QUOTENAME(@tbl)
             + N' FROM ''' + @folder + @f + N'''
                WITH (FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''' + @term + N''', TABLOCK);';
    EXEC sp_executesql @sql;
    FETCH NEXT FROM c INTO @tbl, @f;
END
CLOSE c; DEALLOCATE c;
GO

-- Double-check:
SELECT 'leads'       AS tbl, COUNT(*) AS n, 83200  AS expected FROM [raw].leads       UNION ALL
SELECT 'call_log',           COUNT(*),       237080            FROM [raw].call_log    UNION ALL
SELECT 'agents',             COUNT(*),       18                FROM [raw].agents      UNION ALL
SELECT 'campaigns',          COUNT(*),       6                 FROM [raw].campaigns   UNION ALL
SELECT 'dnc_list',           COUNT(*),       2000              FROM [raw].dnc_list    UNION ALL
SELECT 'agent_daily',        COUNT(*),       1422              FROM [raw].agent_daily;
 
SELECT COUNT(*) AS dong_con_ky_tu_CR FROM [raw].leads WHERE import_date LIKE '%' + CHAR(13) + '%';

SELECT TOP 5 * FROM [raw].leads;