# StepIN

StepIN is an AI-powered iOS app designed to help job seekers prepare for real job interviews through realistic, personalized voice practice.

Instead of practicing with a fixed list of questions, StepIN builds the interview around the role the user is applying for. Users can provide a job title, company, job description, and CV, allowing the interview to be more relevant to their background and target position.

## How It Works

During the interview, the AI acts as a professional interviewer rather than a coach. It asks one question at a time, listens to the user's responses, and moves through different areas of the interview naturally.

Questions can be based on the user's CV, job description, target role, previous answers, and overall interview context.

The interview can also adjust the depth of questions based on the user's responses and ask relevant follow-up questions when additional detail is needed.

After the interview, StepIN provides personalized feedback highlighting strengths and areas for improvement.

## Voice Analysis

StepIN goes beyond analyzing what the user says.

The app uses Core ML and Apple's Sound Analysis framework to analyze vocal delivery on-device during the interview. A custom sound classification model identifies voice patterns such as calm, neutral, and fearful delivery and produces a confidence score for each classification.

The app also measures speaking behavior such as pauses, silence duration, speaking time, and other delivery patterns. These signals can be combined with the interview content to provide more meaningful feedback about the user's overall performance.

## Features

- AI-powered real-time voice interviews
- Personalized questions based on the target role
- CV-based interview questions
- Job description and company context
- Context-aware follow-up questions
- Adaptive question depth
- On-device Core ML voice analysis
- Vocal delivery and pause analysis
- Personalized strengths and areas for improvement
- Interview history
- Goals based on interview results
- Arabic and English support

## Built With

- Swift
- SwiftUI
- OpenAI Realtime API
- Core ML
- Sound Analysis
- AVFoundation
- Swift Concurrency
- Rive
- Xcode

## About the Project

StepIN was developed as part of the Apple Developer Academy Foundation Program in AI.

The project explores how generative AI and on-device machine learning can work together in an iOS experience to solve a practical problem: helping job seekers practice realistic interviews, understand their performance, and become better prepared for the real thing.
