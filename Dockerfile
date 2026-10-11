FROM frappe/erpnext:v16.31.1

# Pull version-16 of India Compliance to match ERPNext v16
RUN bench get-app --branch version-16 https://github.com/resilient-tech/india-compliance.git