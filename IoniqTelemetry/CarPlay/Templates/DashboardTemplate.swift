import CarPlay
import CoreUI

struct DashboardTemplate {
    static func make() -> CPTemplate {
        let items = [
            CPListItem(text: "Battery: 78%", detailText: "SOC", image: UIImage(systemName: "battery.75")),
            CPListItem(text: "Power: 45 kW", detailText: "Current", image: UIImage(systemName: "bolt.fill")),
            CPListItem(text: "Range: 312 km", detailText: "Estimated", image: UIImage(systemName: "map")),
            CPListItem(text: "Charging", detailText: "Not charging", image: UIImage(systemName: "bolt.car"))
        ]
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Ioniq Telemetry", sections: [section])
        return template
    }
}
