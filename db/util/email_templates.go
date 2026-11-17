package util

import (
	"bytes"
	"errors"
	t "html/template"
	"strings"

	"github.com/pocketbase/pocketbase/tools/template"
)

type EmailData struct {
	AppUrl           string
	RecipientName    string
	Content          t.HTML
	Link             string
	FollowerName     string
	Lang             string
	Greeting         string
	Intro            string
	ActionLabel      string
	SignOff          string
	TeamLabel        string
	UnsubscribeLabel string
}

var notificationTemplates = map[NotificationType]string{
	TrailShare:       "{{.Author}} has shared a trail with you: {{.trail}}.",
	ListShare:        "{{.Author}} has shared a list with you: {{.list}}.",
	NewFollower:      "Good news! You have a new follower: {{.follower}}.",
	TrailComment:     "{{.Author}} commented on your trail '{{.trail_name}}': '{{.comment}}'.",
	SummitLogCreate:  "{{.Author}} created a summit log on your trail '{{.trail_name}}'.",
	TrailLike:        "{{.Author}} liked your trail '{{.trail_name}}'.",
	CommentMention:   "{{.Author}} mentioned you in a comment.",
	TrailMention:     "{{.Author}} mentioned you in a trail.",
	SummitLogMention: "{{.Author}} mentioned you in a summit log.",
}

var notificationTemplatesRo = map[NotificationType]string{
	TrailShare:       "{{.Author}} a partajat un traseu cu tine: {{.trail}}.",
	ListShare:        "{{.Author}} a partajat o listă cu tine: {{.list}}.",
	NewFollower:      "Vești bune! Ai un urmăritor nou: {{.follower}}.",
	TrailComment:     "{{.Author}} a comentat la traseul tău „{{.trail_name}}”: „{{.comment}}”.",
	SummitLogCreate:  "{{.Author}} a adăugat o însemnare de vârf la traseul tău „{{.trail_name}}”.",
	TrailLike:        "{{.Author}} a apreciat traseul tău „{{.trail_name}}”.",
	CommentMention:   "{{.Author}} te-a menționat într-un comentariu.",
	TrailMention:     "{{.Author}} te-a menționat într-un traseu.",
	SummitLogMention: "{{.Author}} te-a menționat într-o însemnare de vârf.",
}

func isRomanianLocale(locale string) bool {
	base := strings.ToLower(strings.TrimSpace(locale))
	return base == "ro" || strings.HasPrefix(base, "ro-") || strings.HasPrefix(base, "ro_")
}

func NotificationEmailSubject(locale string) string {
	if isRomanianLocale(locale) {
		return "wanderer - Notificare nouă"
	}
	return "wanderer - New Notification"
}

func GenerateHTML(appUrl string, recipientName string, authorName string, notificationType NotificationType, metadata map[string]string) (string, error) {
	return GenerateLocalizedHTML("en", appUrl, recipientName, authorName, notificationType, metadata)
}

func GenerateLocalizedHTML(locale string, appUrl string, recipientName string, authorName string, notificationType NotificationType, metadata map[string]string) (string, error) {
	registry := template.NewRegistry()

	templates := notificationTemplates
	isRo := isRomanianLocale(locale)
	if isRo {
		templates = notificationTemplatesRo
	}

	// Get custom content template for the notification type
	customTemplate, exists := templates[notificationType]
	if !exists {
		return "", errors.New("unknown notification type")
	}

	// Create content template with dynamic data
	contentTmpl, err := t.New("content").Parse(customTemplate)
	if err != nil {
		return "", err
	}

	// Render the custom content with data
	renderedMetadata := make(map[string]string, len(metadata)+1)
	for k, v := range metadata {
		renderedMetadata[k] = v
	}
	renderedMetadata["Author"] = authorName
	var contentBuffer bytes.Buffer
	err = contentTmpl.Execute(&contentBuffer, renderedMetadata)
	if err != nil {
		return "", err
	}

	// Assemble the final email with boilerplate and custom content
	content := EmailData{
		AppUrl:           appUrl,
		RecipientName:    recipientName,
		Content:          t.HTML(contentBuffer.String()),
		Lang:             "en",
		Greeting:         "Hello " + recipientName + ",",
		Intro:            "You have a new notification:",
		ActionLabel:      "Check it out!",
		SignOff:          "Kind regards,",
		TeamLabel:        "Your wanderer team",
		UnsubscribeLabel: "Unsubscribe",
	}
	if isRo {
		content.Lang = "ro"
		content.Greeting = "Salut " + recipientName + ","
		content.Intro = "Ai o notificare nouă:"
		content.ActionLabel = "Vezi detalii"
		content.SignOff = "Cu drag,"
		content.TeamLabel = "Echipa wanderer"
		content.UnsubscribeLabel = "Dezabonare"
	}

	html, err := registry.LoadFiles(
		"templates/mail/notification.html",
	).Render(content)

	if err != nil {
		return "", err
	}

	return html, nil
}
