-- ============================================
-- PHOTO CONTEST VOTING SYSTEM - DATABASE SCHEMA
-- ============================================

-- Drop database if exists and create fresh
DROP DATABASE IF EXISTS photo_contest_system;
CREATE DATABASE photo_contest_system;
USE photo_contest_system;

-- ============================================
-- PARENT TABLES (No Foreign Keys)
-- ============================================

-- Table 1: User
CREATE TABLE User (
    UserID INT PRIMARY KEY AUTO_INCREMENT,
    Name VARCHAR(100) NOT NULL,
    Email VARCHAR(100) UNIQUE NOT NULL,
    Password VARCHAR(255) NOT NULL,
    Coins INT DEFAULT 10,
    CONSTRAINT chk_coins CHECK (Coins >= 0),
    INDEX idx_email (Email)
);

-- Table 2: Admin
CREATE TABLE Admin (
    AdminID INT PRIMARY KEY AUTO_INCREMENT,
    Name VARCHAR(100) NOT NULL,
    Email VARCHAR(100) UNIQUE NOT NULL,
    Password_hash VARCHAR(255) NOT NULL,
    CONSTRAINT chk_admin_email UNIQUE (Email)
);

-- Table 3: Contest
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

-- ============================================
-- CHILD TABLES (With Foreign Keys)
-- ============================================

-- Table 4: Photo
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

-- ============================================
-- JUNCTION/RELATIONSHIP TABLES
-- ============================================

-- Table 5: PhotoContestSubmission (M:N between Photo and Contest)
CREATE TABLE PhotoContestSubmission (
    SubmissionID INT PRIMARY KEY AUTO_INCREMENT,
    PhotoID INT NOT NULL,
    ContestID INT NOT NULL,
    SubmissionTimestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    SubmissionStatus ENUM('Pending', 'Approved', 'Rejected') DEFAULT 'Pending',
    FOREIGN KEY (PhotoID) REFERENCES Photo(PhotoID) ON DELETE CASCADE,
    FOREIGN KEY (ContestID) REFERENCES Contest(ContestID) ON DELETE CASCADE,
    UNIQUE KEY unique_submission (PhotoID, ContestID), -- A photo can only be submitted once per contest
    INDEX idx_contest_submissions (ContestID),
    INDEX idx_photo_submissions (PhotoID)
);

-- Table 6: Votes
CREATE TABLE Votes (
    VoteID INT PRIMARY KEY AUTO_INCREMENT,
    UserID INT NOT NULL,
    PhotoID INT NOT NULL,
    ContestID INT NOT NULL,
    Vote_timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (UserID) REFERENCES User(UserID) ON DELETE CASCADE,
    FOREIGN KEY (PhotoID) REFERENCES Photo(PhotoID) ON DELETE CASCADE,
    FOREIGN KEY (ContestID) REFERENCES Contest(ContestID) ON DELETE CASCADE,
    UNIQUE KEY unique_vote (UserID, PhotoID, ContestID), -- User can vote only once per photo per contest
    INDEX idx_contest_votes (ContestID),
    INDEX idx_photo_votes (PhotoID),
    INDEX idx_user_votes (UserID)
);

-- ============================================
-- SAMPLE DATA FOR TESTING
-- ============================================

-- Insert Admins
INSERT INTO Admin (Name, Email, Password_hash) VALUES
('John Doe', 'john.admin@pesu.edu', '$2b$10$hashedpassword1'),
('Jane Smith', 'jane.admin@pesu.edu', '$2b$10$hashedpassword2');

-- Insert Users
INSERT INTO User (Name, Email, Password, Coins) VALUES
('Alice Johnson', 'alice@student.pesu.edu', 'password123', 15),
('Bob Williams', 'bob@student.pesu.edu', 'password456', 20),
('Charlie Brown', 'charlie@student.pesu.edu', 'password789', 10),
('Diana Prince', 'diana@student.pesu.edu', 'password101', 25),
('Eve Martinez', 'eve@student.pesu.edu', 'password202', 12);

-- Insert Contests (with specific times for simulation)
INSERT INTO Contest (Title, StartDate, EndDate, Status, Max_participants, Prize_points, Entry_fee, Manager_id) VALUES
('Nature Photography 2024', '2024-10-01 09:00:00', '2024-10-31 23:59:59', 'Active', 50, 100, 5, 1),
('Urban Life Contest', '2024-11-01 10:00:00', '2024-11-30 18:00:00', 'Upcoming', 75, 150, 10, 2),
('Black & White Challenge', '2024-09-01 08:00:00', '2024-09-30 20:00:00', 'Completed', 40, 200, 8, 1),
-- For immediate testing - Contest starting in 5 minutes, ending in 1 hour
('Quick Test Contest', NOW() + INTERVAL 5 MINUTE, NOW() + INTERVAL 1 HOUR, 'Upcoming', 30, 50, 3, 1),
('Free Entry Contest', '2024-12-01 00:00:00', '2024-12-31 23:59:59', 'Upcoming', 100, 50, 0, 2);

-- Insert Photos
INSERT INTO Photo (Title, FilePath, UserID) VALUES
('Sunset Over Mountains', '/uploads/alice_sunset.jpg', 1),
('City Lights at Night', '/uploads/bob_citynight.jpg', 2),
('Morning Dew', '/uploads/alice_dew.jpg', 1),
('Street Art', '/uploads/charlie_streetart.jpg', 3),
('Ocean Waves', '/uploads/diana_ocean.jpg', 4);

-- Insert Photo Contest Submissions
INSERT INTO PhotoContestSubmission (PhotoID, ContestID, SubmissionStatus) VALUES
(1, 1, 'Approved'),  -- Alice's sunset in Nature contest
(3, 1, 'Approved'),  -- Alice's dew in Nature contest
(2, 2, 'Pending'),   -- Bob's city in Urban contest
(4, 2, 'Approved'),  -- Charlie's street art in Urban contest
(5, 1, 'Approved');  -- Diana's ocean in Nature contest

-- Insert Votes
INSERT INTO Votes (UserID, PhotoID, ContestID) VALUES
(2, 1, 1),  -- Bob votes for Alice's sunset
(3, 1, 1),  -- Charlie votes for Alice's sunset
(4, 1, 1),  -- Diana votes for Alice's sunset
(1, 5, 1),  -- Alice votes for Diana's ocean
(2, 5, 1),  -- Bob votes for Diana's ocean
(5, 1, 1);  -- Eve votes for Alice's sunset

-- ============================================
-- VERIFICATION QUERIES
-- ============================================

-- View all tables
SELECT 'Users' AS TableName, COUNT(*) AS RecordCount FROM User
UNION ALL
SELECT 'Admins', COUNT(*) FROM Admin
UNION ALL
SELECT 'Contests', COUNT(*) FROM Contest
UNION ALL
SELECT 'Photos', COUNT(*) FROM Photo
UNION ALL
SELECT 'Submissions', COUNT(*) FROM PhotoContestSubmission
UNION ALL
SELECT 'Votes', COUNT(*) FROM Votes;