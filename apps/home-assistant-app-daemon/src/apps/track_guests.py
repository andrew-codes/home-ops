import hassapi as hass
import mqttapi as mqtt
import json


class TrackGuests(hass.Hass, mqtt.Mqtt):
    def initialize(self):
        """Listen for device name changes."""
        self.call_service("mqtt/subscribe",
                          topic="guest-registrar-unifi/guests")
        self.listen_event(self.track_guests,
                          "MQTT_MESSAGE", topic='guest-registrar-unifi/guests')

    def track_guests(self, event_name, data, kwargs):
        # Wait for ten seconds
        self.log("Waiting for 10 seconds before processing device rename event.")
        payload = data["payload"]
        self.run_in(self.process_track_guests, 10, data=payload)

    def process_track_guests(self, kwargs):
        data = kwargs.get("data")
        if not data:
            self.log("No data found in the event.")
            return

        json_data = json.loads(data)

        # Open and read the file located at /config/guests.json, parse it as JSON.
        try:
            with open('/config/guests.json', 'r') as file:
                self.log("Opened device registry file")
                existing_macs = json.load(file)

            if not existing_macs:
                self.log("No existing macs found.")
                existing_macs = []

            unique_macs = set(existing_macs)
            for mac in json_data:
                if mac not in unique_macs:
                    self.log(f"New MAC address found: {mac}")
                    unique_macs.add(mac)
                else:
                    self.log(f"MAC address {mac} already exists.")

            # Write the updated list of MAC addresses back to the file
            with open('/config/guests.json', 'w') as file:
                json.dump(list(unique_macs), file, indent=2)
                self.log("Updated guests.json with new MAC addresses.")

            template_string = 'template:\n  - binary_sensor:\n    - name: "Tracked Guests"\n      state: >\n        '
            if not unique_macs:
                self.log("No unique MAC addresses found.")
                template_string += 'not_home'
            else:
                for mac in unique_macs:
                    mac = mac.replace(':', '_')
                    if mac == unique_macs[-1]:
                        template_string += f'{{% if is_state("device_tracker.unifi_default_{mac}", "home") %}}'
                    else:
                        template_string += f'{{% if is_state("device_tracker.unifi_default_{mac}", "home") %}} or '

            with open('/config/packages/binary_sensor/tracked_guests.yaml', 'w') as file:
                file.write(template_string)
                self.log("Updated guests.yaml with new MAC addresses.")

            # Reload home assistant template configuration
            self.call_service("template.reload")
            self.log("Reloaded home assistant template configuration.")

        except FileNotFoundError:
            self.log("guests.json file not found.")
            # Create the file if it doesn't exist
            with open('/config/guests.json', 'w') as file:
                json.dump([], file)
            self.log("Created guests.json file.")
            self.track_guests(data=data)
        except json.JSONDecodeError:
            self.log("Error decoding JSON from device registry file.")
        except Exception as e:
            self.log(f"An unexpected error occurred: {e}")
