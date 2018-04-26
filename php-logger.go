package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math"
	"os"
	"regexp"
	"strings"
	"syscall"
	"time"
)

var (
	confFilePath = flag.String("config", "config.yaml", "Config file path.")
)

var (
	conf = getConfig()
)

func init() {
	flag.Parse()
	createPipes()
}

func main() {

	start := time.Now()

	oscillationPeriod := 10 * time.Minute
	oscillationFactor := func() float64 {
		return 2 + math.Sin(math.Sin(2*math.Pi*float64(time.Since(start))/float64(oscillationPeriod)))
	}

	for _, v := range conf.Inputs {

		go func(v input) {
			pipe, err := os.OpenFile(v.Path, os.O_RDONLY, os.ModeNamedPipe)

			if err != nil {
				log.Panic(err)
			}
			var completeString string
			multilineTimer := time.Now()
			for {
				reader := bufio.NewReader(pipe)
				scanner := bufio.NewScanner(reader)

				if v.Multiline.Enabled {
					if time.Since(multilineTimer).Seconds() > v.Multiline.FlushInterval && len(completeString) > 0 {
						parseMessage(&completeString, &v)
						completeString = ""
					}
					for scanner.Scan() {
						line := scanner.Text()
						if isMultilineStart(&line, &v.Multiline.FirstLine) {
							parseMessage(&completeString, &v)
							completeString = line
						} else {
							completeString += " " + line
						}
					}
				} else {
					for scanner.Scan() {
						line := scanner.Text()
						parseMessage(&line, &v)
					}
				}
				time.Sleep(time.Duration(50*oscillationFactor()) * time.Millisecond)
			}
		}(v)
	}

	for {
		time.Sleep(time.Duration(500*oscillationFactor()) * time.Millisecond)
	}
}

func isMultilineStart(line *string, parser *string) bool {
	newLineStart := regexp.MustCompile(*parser)
	if newLineStart.MatchString(*line) {
		return true
	}
	return false
}

func parseMessage(msg *string, conf *input) {
	*msg = strings.Trim(*msg, " ")
	result := make(map[string]string)
	if len((*conf).Parsers) > 0 {
		for _, parser := range (*conf).Parsers {
			rExp, err := regexp.Compile(parser)

			if err != nil {
				log.Println(err)
				continue
			}

			match := rExp.FindStringSubmatch(*msg)

			if len(match) == len(rExp.SubexpNames()) && len(match) > 1 {
				for k, v := range rExp.SubexpNames() {
					if k != 0 && v != "" {
						result[v] = match[k]
					}
				}
				wrapJSON(&result, conf)
				break
			}
		}
		if len(result) == 0 {
			if len(*msg) > 0 {
				result["message"] = *msg
				wrapJSON(&result, conf)
			}
		}
	} else {
		if len(*msg) > 0 {
			result["message"] = *msg
			wrapJSON(&result, conf)
		}
	}
}

func wrapJSON(msg *map[string]string, conf *input) {
	err := json.Unmarshal(([]byte((*msg)["message"])), msg)

	if err == nil {
		delete((*msg), "message")
	}

	overridePHPError(msg)

	if len((*conf).Tags) > 0 {
		addTagsToMsg(msg, conf)
	}

	val, err := json.Marshal(*msg)
	if err != nil {
		log.Println(err)
	}
	fmt.Println(string(val))
}

func addTagsToMsg(msg *map[string]string, conf *input) {
	for _, v := range (*conf).Tags {
		if strings.HasPrefix(v.Value, "$") {
			(*msg)[v.Name] = os.Getenv(strings.TrimLeft(v.Value, "$"))
		} else {
			(*msg)[v.Name] = v.Value
		}
	}
}

func overridePHPError(msg *map[string]string) {
	if (*msg)["event_type"] == "php.error" {
		(*msg)["php_error_log"] = fmt.Sprintf("{\"level\":\"%s\", \"error\": \"%s\"}", (*msg)["severity"], (*msg)["msg"])
	}
}

func createPipes() {
	for _, v := range conf.Inputs {
		if _, err := os.Stat(v.Path); os.IsNotExist(err) {
			err = syscall.Mkfifo(v.Path, 0666)
			if err != nil {
				log.Panic(err)
			}
			log.Printf("Pipe %s has been created", v.Path)
		}
	}
}
