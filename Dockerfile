# --------------- Stage 1 : Jar Builder --------------- #
# Maven Image
FROM maven:3.8.3-openjdk-17 AS builder

# Set the working directory inside the container
WORKDIR /app

# Copy the project files to the working directory
COPY . /app

# Build the application and package it into a jar file
RUN mvn clean install -DskipTests=true

# --------------- Stage 2 : Application Runner --------------- #
# Import Small Size Java Image
FROM amazoncorretto:17.0.8-alpine3.18

# Set the working directory inside the container
ENV APP_HOME /usr/src/app
WORKDIR $APP_HOME

# Copy the jar file from the builder stage to the running container
COPY --from=builder /app/target/*.jar $APP_HOME/app.jar

# Expose the application port
EXPOSE 8080

# Command to run the application
CMD ["java", "-jar", "app.jar"]
