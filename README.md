# Photography Contest System

A web-based application for organizing and participating in photography contests. Users can register, submit their photos to contests, vote on other submissions, and view leaderboards. Admins can manage contests, approve submissions, and finalize contests.

## Features

- User registration and login
- Admin registration and login
- Create and manage photography contests
- Submit photos to contests
- Vote for photos in contests
- Leaderboard for contests
- User dashboard with statistics
- Admin dashboard with analytics
- Role-based access control (user/admin)
- Responsive design with Bootstrap

---

## Technologies Used

- **Backend**: Flask (Python)
- **Frontend**: Jinja2
- **Database**: MySQL
- **ORM**: MySQL Connector
- **Authentication**: Werkzeug
- **Environment Management**: Python-dotenv

---

## Setup Instructions

### Prerequisites

Ensure you have the following installed:

- Python 3.8+
- MySQL Server
- pip (Python package manager)

---

# Steps to Set Up

## 1. Clone the Repository

```bash
git clone https://github.com/shre-555/photography_contest.git
cd photography_contest
````

## 2. Install Dependencies

Install the required dependencies from `requirements.txt`:

```bash
pip install -r requirements.txt
```

## 3. Configure the Environment Variables

### Copy the `.env.example` file to `.env`

```bash
cp .env.example .env
```

### Edit the `.env` file

Open the `.env` file and set the following variables:

```env
SECRET_KEY=your-secret-key
DB_HOST=localhost
DB_USER=root
DB_PASSWORD=your-password
DB_NAME=photo_contest_system
FLASK_ENV=development
FLASK_DEBUG=True
```

**Note**: It is important to replace `your-secret-key` and database credentials with your actual values.


## 4. Set Up the Database

Open MySQL and execute the provided schema to create the necessary database and tables.

```bash
mysql -u root -p
```

Then run the SQL script (photo_contest.sql)

## 5. Run the Application

Run the Flask application:

```bash
flask run
```

The application will be available at [http://127.0.0.1:5000](http://127.0.0.1:5000).



