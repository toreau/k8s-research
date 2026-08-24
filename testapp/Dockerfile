FROM golang:1.27-alpine AS build
WORKDIR /src
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux GO111MODULE=off go build -o /k8s-testapp main.go

FROM alpine:3.20
COPY --from=build /k8s-testapp /k8s-testapp
USER 150
EXPOSE 8080
ENTRYPOINT ["/k8s-testapp"]
