-- ============================================
-- SECTION 0: DATABASE SETUP
-- ============================================
DROP DATABASE IF EXISTS photo_contest_system;
CREATE DATABASE photo_contest_system;
USE photo_contest_system;

-- ============================================
-- SECTION 1: TABLE CREATION (No Changes)
-- ============================================

CREATE TABLE User (
    UserID INT PRIMARY KEY AUTO_INCREMENT,
    Name VARCHAR(100) NOT NULL,
    Email VARCHAR(100) UNIQUE NOT NULL,
    Password VARCHAR(255) NOT NULL,
    Coins INT DEFAULT 10,
    CONSTRAINT chk_coins CHECK (Coins >= 0),
    INDEX idx_email (Email)
);

CREATE TABLE Admin (
    AdminID INT PRIMARY KEY AUTO_INCREMENT,
    Name VARCHAR(100) NOT NULL,
    Email VARCHAR(100) UNIQUE NOT NULL,
    Password_hash VARCHAR(255) NOT NULL
);

CREATE TABLE Contest (
    ContestID INT PRIMARY KEY AUTO_INCREMENT,
    Title VARCHAR(200) NOT NULL,
    StartDate DATETIME NOT NULL,
    EndDate DATETIME NOT NULL,
    Status ENUM('Upcoming', 'Active', 'Completed', 'Cancelled') DEFAULT 'Upcoming',
    Max_participants INT DEFAULT 100,
    Prize_points INT DEFAULT 0,
    Entry_fee INT DEFAULT 5,
    Result VARCHAR(500),
    Manager_id INT,
    CONSTRAINT chk_dates CHECK (EndDate >= StartDate),
    CONSTRAINT chk_max_participants CHECK (Max_participants > 0),
    CONSTRAINT chk_prize_points CHECK (Prize_points >= 0),
    CONSTRAINT chk_entry_fee CHECK (Entry_fee >= 0),
    INDEX idx_status (Status),
    INDEX idx_dates (StartDate, EndDate),
    FOREIGN KEY (Manager_id) REFERENCES Admin(AdminID) ON DELETE SET NULL
);

CREATE TABLE Photo (
    PhotoID INT PRIMARY KEY AUTO_INCREMENT,
    Title VARCHAR(200) NOT NULL,
    FilePath VARCHAR(500) NOT NULL,
    UploadDate DATETIME DEFAULT CURRENT_TIMESTAMP,
    UserID INT NOT NULL,
    FOREIGN KEY (UserID) REFERENCES User(UserID) ON DELETE CASCADE,
    INDEX idx_user_photo (UserID),
    INDEX idx_upload_date (UploadDate)
);

CREATE TABLE PhotoContestSubmission (
    SubmissionID INT PRIMARY KEY AUTO_INCREMENT,
    PhotoID INT NOT NULL,
    ContestID INT NOT NULL,
    SubmissionTimestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    SubmissionStatus ENUM('Pending', 'Approved', 'Rejected') DEFAULT 'Pending',
    FOREIGN KEY (PhotoID) REFERENCES Photo(PhotoID) ON DELETE CASCADE,
    FOREIGN KEY (ContestID) REFERENCES Contest(ContestID) ON DELETE CASCADE,
    UNIQUE KEY unique_submission (PhotoID, ContestID),
    INDEX idx_contest_submissions (ContestID),
    INDEX idx_photo_submissions (PhotoID)
);

CREATE TABLE Votes (
    VoteID INT PRIMARY KEY AUTO_INCREMENT,
    UserID INT NOT NULL,
    PhotoID INT NOT NULL,
    ContestID INT NOT NULL,
    Vote_timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (UserID) REFERENCES User(UserID) ON DELETE CASCADE,
    FOREIGN KEY (PhotoID) REFERENCES Photo(PhotoID) ON DELETE CASCADE,
    FOREIGN KEY (ContestID) REFERENCES Contest(ContestID) ON DELETE CASCADE,
    UNIQUE KEY unique_vote (UserID, PhotoID, ContestID),
    INDEX idx_contest_votes (ContestID),
    INDEX idx_photo_votes (PhotoID),
    INDEX idx_user_votes (UserID)
);

CREATE TABLE Contest_Audit (
    AuditID INT PRIMARY KEY AUTO_INCREMENT,
    ContestID INT NOT NULL,
    Action VARCHAR(100),
    Timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    INDEX idx_audit_contest (ContestID)
);

-- Adding the foreign key constraint correctly
ALTER TABLE Contest_Audit
ADD CONSTRAINT fk_contest_audit_contest 
FOREIGN KEY (ContestID) REFERENCES Contest(ContestID) ON DELETE CASCADE;
